local registry = {}

local state = {
    config = nil,
    writer = nil,
    objects = {},
}

function registry.init(config, writer)
    state.config = config
    state.writer = writer
    state.objects = {}
end

function registry.reset()
    state.config = nil
    state.writer = nil
    state.objects = {}
end

function registry.snapshot()
    return {}
end

return registry
