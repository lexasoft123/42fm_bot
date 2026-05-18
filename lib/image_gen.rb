require_relative 'image_gen/adapter'
require_relative 'image_gen/flux_adapter'
require_relative 'image_gen/atlas_adapter'
require_relative 'image_gen/closerouter_adapter'

# Image-generation facade. Picks an adapter from Settings.image_gen and
# returns a fresh instance per call (adapters are cheap to construct, mostly
# config reads). Used by ImageGenTaskHandler.
#
# Provider snapshotting: the handler calls #current_adapter at submit time to
# get the configured backend, then writes its #name into task.params. On the
# next poll it calls #adapter_for(snapshot) so a config flip mid-flight (e.g.
# operator changing image_gen.provider during the prod cutover) doesn't route
# the poll to a different prediction id space.
module ImageGen
  ADAPTERS = {
    'flux'        => FluxAdapter,
    'atlas'       => AtlasAdapter,
    'closerouter' => CloseRouterImgAdapter,
  }.freeze

  def self.current_adapter
    name = Settings.image_gen&.dig('provider') or
      raise 'image_gen.provider not configured'
    klass = ADAPTERS[name] or
      raise "unknown image_gen provider: #{name.inspect} (known: #{ADAPTERS.keys.inspect})"
    klass.new
  end

  # Used on poll-side. name is the value snapshotted into task.params['provider']
  # at submit. Falls back to current_adapter for legacy rows that predate the
  # snapshot, preserving today's behavior.
  def self.adapter_for(name)
    klass = ADAPTERS[name.to_s] or return current_adapter
    klass.new
  end
end
