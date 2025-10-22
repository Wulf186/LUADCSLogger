# Agents Log

## Task Overview
- Goal: design a Lua-based DCS logger reproducing Tacview ACMI output from `Tacview-20230312-170650-DCS.txt.acmi`.
- Current focus: planning phase; no code changes yet.

## Reference Data
- **ACMI sample** (`Tacview-20230312-170650-DCS.txt.acmi`)
  - Header declares `FileType=text/acmi/tacview`, `FileVersion=2.1`, and mission metadata written as `0,<Key>=<Value>`.
  - Timeline markers appear as `#<seconds>` to separate frame batches; values are fractional seconds since recording start.
  - Object state lines follow `<objectId>,T=lon|lat|alt|pitch|roll|heading|x|z|agl,<extraKey=Value,...>`.
  - Optional attributes observed: `Type`, `Color`, `Coalition`, `Name`, `Pilot`, `Group`, `Country`, `IAS`, `FuelWeight`, `Throttle`, `PilotHeadYaw`, `PilotHeadRoll`, `PilotHeadPitch`.
  - Some `T=` tuples omit elements but keep pipe separators to preserve positional meaning.
  - Metadata section includes non-ASCII characters (Author/Comments); ensure UTF-8 compatibility when writing.
- **Existing scripts**
  - `Export.lua` loads `TacviewGameExport.lua` via `dofile(lfs.writedir()..'Scripts/TacviewGameExport.lua')`.
  - `TacviewGameExport.lua` guards against duplicate loading, adjusts `package.cpath`, loads `tacview` DLL, and hooks `LuaExportStart`, `LuaExportAfterNextFrame`, `LuaExportStop`.
  - `Hooks/TacviewGameGUI.lua` demonstrates GUI callback registration with `DCS.setUserCallbacks` and fallback DLL loading.
  - These provide patterns for safe callback chaining and Saved Games path resolution without depending on external modules.

## ACMI Format Specification
- **Encoding**: UTF-8 text; allow Unicode payloads in metadata while keeping control tokens ASCII; lines end with `\n`.
- **Header block**: ordered key/value pairs (`FileType`, `FileVersion`, mission metadata) appear before timeline data; mission-wide fields reuse emitter id `0`.
- **Reference frame**: `ReferenceLongitude`/`ReferenceLatitude` specify base degrees; per-object longitude/latitude values store offsets added to references to recover absolute degrees.
- **Timeline markers**: `#<seconds>` introduces data captured at simulation time; timestamps increment monotonically and include fractional seconds.
- **Transform lines**: `<id>,T=lonOff|latOff|alt|roll|pitch|heading|x|z|agl` where trailing components can be blank; orientation expects degrees; `x`/`z` align with DCS world meters; `agl` commonly holds terrain altitude or auxiliary heading if altitude missing.
- **Property lines**: Additional telemetry uses `,<Key>=<Value>` pairs (e.g., `IAS`, `FuelWeight`, `Throttle`, `PilotHead*`); multiple pairs separated by commas; order preserved as emitted.
- **Lifecycle**: Object ids persist across frames; missing `T` entries imply no update; absence of timeline markers after last frame signifies end-of-file.

## DCS Data Mapping
- **Mission metadata**: `DCS.getMissionFilename()`, `DCS.getMissionName()`, `DCS.getMissionDescription()` feed `Title`, `Briefing`, and auxiliary header fields; derive `Author`/`Comments` from mission file metadata or allow manual overrides via config.
- **Timekeeping**: `DCS.getModelTime()` supplies elapsed seconds for timeline markers; `DCS.getRealTime()` can backfill recording timestamps; convert to ISO-8601 for `RecordingTime`.
- **Reference coordinates**: Sample world objects on first frame to compute `ReferenceLongitude/Latitude` (floor or rounded base) using `LoGetSelfData().LatLongAlt` and fallback to mission start position.
- **Object enumeration**: `LoGetWorldObjects()` returns dynamic units with `LatLongAlt`, `Type`, `Name`, `Country`, `Coalition`, `Heading`, `Pitch`, `Roll`; supplement with `LoGetSelfData()` for player aircraft and correlate via `LoGetPlayerPlaneId()`.
- **Static scenery**: If `LoGetWorldObjects()` omits statics, parse `env.mission` at startup to seed a registry of immobile units, converting mission `x/z` coordinates to lat/long through `coord.LOtoLL`.
- **Telemetry extras**: Air data via `LoGetTrueAirspeed()`, `LoGetIndicatedAirSpeed()`, `LoGetVerticalVelocity()`, `LoGetEngineInfo()`, `LoGetSelfData().AoA`, `LoGetSelfData().MachNumber`; head tracking from `LoGetCameraPosition()`, throttle from `LoGetEngineInfo().RPM.left/right`.
- **Coalition & color**: Map `coalition.side.RED/BLUE/NEUTRAL` to ACMI `Coalition` strings and colors (Red/Blue/Neutral); for ground statics assign `Color` per sample conventions (Allies=Red, Enemies=Blue).
- **Identifiers**: Use DCS internal `ObjectID` from `LoGetWorldObjects` when stable; fallback to hashed combination of unit name and spawn time to maintain persistent `<id>` across frames and reuse prefixes (hex style) to remain Tacview-compatible.

## Logger Architecture Sketch
- **Module layout**: Create `Scripts/DCSLogger/` with `core.lua` (public entry), `object_registry.lua`, `frame_sampler.lua`, `acmi_writer.lua`, and `config.lua`; expose a single `require('DCSLogger.core')` from `Export.lua`.
- **Startup flow**: `LuaExportStart` initializes config, resolves output path under `lfs.writedir()..'Logs\\DCSLogger'`, computes reference coordinates/mission metadata, writes header block, and seeds static registry.
- **Frame loop**: `LuaExportAfterNextFrame` delegates to `frame_sampler.tick(simTime)` which throttles updates (e.g., 10 Hz), queries DCS sensors, updates the registry, serializes transformed objects, and appends lines to a buffered writer before flushing when buffer exceeds thresholds.
- **Shutdown**: `LuaExportStop` flushes remaining buffered lines, writes closing diagnostics, and closes file handles; guard against multiple invocations and nil handles.
- **Compatibility**: Core module captures previous export callbacks (Start/Stop/AfterNextFrame/BeforeNextFrame) and invokes them after custom logic; provide `logger.unregister()` to clean up when unloading.
- **Diagnostics**: Use `log.write('DCSLOGGER', log.INFO, ...)` for lifecycle messages and optional debug dumps governed by `config.verbose`.
- **Extensibility**: Keep `acmi_writer` isolated from DCS APIs so future outputs (JSON, live streaming) can reuse registry data without touching export hooks.

## Implementation Checklist
- **Core bootstrap**: Implement `core.lua` to wrap export callbacks, manage config loading, and expose `start/update/stop` entry points.
- **Object registry**: Build registry module to track known units, assign stable IDs, detect despawns, and maintain metadata cache (coalition, type, colors).
- **Sampler**: Implement `frame_sampler` with throttled tick, fetching data from `LoGetWorldObjects`, merging with player-centric sensors, and queuing transform/property updates.
- **Writer**: Create `acmi_writer` responsible for formatting header, timeline markers, and per-object lines with configurable precision and newline buffering.
- **Static seeding**: Add mission parser that reads `env.mission` once, registers statics, and provides transformation helpers for `x/z` to lat/long.
- **Configuration**: Supply default config (sampling rate, output directory, toggle for optional telemetry) with override support via Saved Games file.

## Testing Strategy
- **Smoke runs**: Fly short single-player mission to confirm file creation, header integrity, and absence of `dcs.log` errors.
- **Data verification**: Compare generated ACMI against Tacview sample using diff scripts focusing on field presence, order, and numeric precision tolerances.
- **Scenario coverage**: Validate with mixed unit types (air, ground, statics), multiplayer session, and long-duration flight to monitor buffer flushing.
- **Regression hooks**: Add optional debug mode that logs registry churn counts and sampler timing to help diagnose future issues.

## Documentation & Maintenance Notes
- **Installation guide**: Document file placement (Saved Games `Export.lua` update, new `Scripts/DCSLogger` folder) and configuration toggles.
- **User options**: Describe how to adjust sampling rate, output directory, and telemetry flags through config file.
- **Troubleshooting**: Provide common error messages (missing LuaSocket, permission issues) and guidance on enabling debug logging.
- **Maintenance backlog**: Track future enhancements such as event logging, real-time streaming, and integration with other tools (e.g., AWACS overlays).

## Immediate Next Steps
- Flight-test the current build to confirm transform accuracy (lat/lon offsets, altitude/AGL, heading) against recorded Tacview data.
- Validate extended telemetry fields (IAS, throttle, pilot head angles, fuel) against Tacview outputs and tune formatting/units if needed.
- Validate coalition/type mappings and ensure despawn handling leaves appropriate gaps versus Tacview output.
- Introduce friendly type/coalition/country string mapping to replace numeric identifiers in `Type=` and `Country=` fields.
- Produce a test ACMI via DCS, diff it against the sample, and iterate on ordering/precision gaps.

## Development Plan
1. Requirements Finalization `[x]`
   - Capture expected output format from sample ACMI file.
   - Identify reusable patterns from bundled Tacview scripts.
2. Format Specification Draft `[x]`
   - Document mandatory header keys, timeline semantics, and field ordering for `T=` tuples.
   - Define numeric formatting (precision, decimal separator), encoding (UTF-8), and handling of missing data.
3. DCS Data Mapping `[x]`
   - List DCS export API calls for world objects, player state, and mission metadata.
   - Map DCS enumerations (Category, UnitType, coalition) to ACMI `Type`, `Color`, `Coalition`.
   - Design ID assignment strategy mirroring sample hexadecimal-style identifiers.
4. Logger Architecture Design `[x]`
   - Specify Lua modules/components (initialization hook, sampler, serializer, writer).
   - Plan lifecycle: initialize file in `LuaExportStart`, write frames in `LuaExportAfterNextFrame`, finalize in `LuaExportStop`.
   - Choose output directory/name pattern (e.g., `Tacview-<UTC>-DCS.txt.acmi`) using `lfs.writedir()`.
   - Decide buffering strategy to balance performance vs data safety (periodic flush, final flush on stop).
5. Implementation Tasks Breakdown `[x]`
   - Build shared utility functions (timekeeping, string formatting, sanitization).
   - Implement metadata writer (mission info, reference coordinates).
   - Create object registry tracking spawn/despawn, static vs dynamic units.
   - Implement per-frame state serialization matching sample structure, including optional telemetry when available.
   - Ensure compatibility with other export scripts by chaining callbacks.
6. Testing & Validation Strategy `[x]`
   - Outline mission scenarios for verification (single aircraft, mixed coalitions, long sessions).
   - Devise diff-based comparison against sample output (field presence, ordering).
   - Plan logging/debug approach and fallbacks when API returns nil.
7. Documentation & Maintenance `[x]`
   - Draft installation and configuration instructions for end users.
   - Record troubleshooting steps (common DCS export pitfalls, permissions).
   - List potential enhancements (event logging, real-time streaming) for future phases.

## Progress Log
- 2025-10-21: Initial analysis completed; requirements captured from sample file and Tacview scripts.
- 2025-10-21: Drafted ACMI format specification from sample recording; plan step 2 completed.
- 2025-10-21: Outlined DCS data sources to populate ACMI fields; plan step 3 (data mapping) completed.
- 2025-10-21: Drafted module architecture and runtime workflow; plan step 4 completed.
- 2025-10-21: Completed implementation breakdown, testing strategy, and documentation notes; plan steps 5-7 completed.
- 2025-10-21: Scaffolded DCS logger modules and wired `Export.lua` to load `DCSLoggerGameExport.lua`; ready to implement sampling/serialization.
- 2025-10-21: Updated config/sampler to log every export frame (Tacview frequency) with optional throttling via `samplingRateHz`.
- 2025-10-21: Implemented header writer hooks, frame sampler integration, and preliminary object registry to capture dynamic units each frame.
- 2025-10-21: Seeded mission statics, persisted them in the registry, and began populating ACMI transform/property lines for every export tick.
- 2025-10-21: Refined transform data (lon/lat offsets, world X/Z, altitude/AGL) with cartesian fallbacks and precision guards to better match Tacview output.
- 2025-10-21: Added optional telemetry export (IAS, Mach, fuel, throttle, pilot head angles) for the player aircraft with configurable toggles.
- 2025-10-21: Implemented delta-based frame emission, monotonic timing fallback, and telemetry deduplication to reduce file size closer to Tacview output.
