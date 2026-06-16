require_relative 'test_helper'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Settings.image_gen accessor (same stub the adapter test uses).
unless Settings.respond_to?(:image_gen)
  Settings.singleton_class.send(:define_method, :image_gen) { @image_gen }
  Settings.singleton_class.send(:define_method, :image_gen=) { |v| @image_gen = v }
end

require_relative '../lib/image_gen'

class ImageGenCatalogTest < Minitest::Test
  CATALOG = {
    'default_model' => 'nano-banana-2',
    'models' => {
      'nano-banana-2' => { 'provider' => 'atlas', 't2i' => 'google/nano-banana-2/text-to-image',
                           'edit' => 'google/nano-banana-2/edit', 'desc' => 'NB2 desc' },
      'wan-2.7'       => { 'provider' => 'atlas', 't2i' => 'alibaba/wan-2.7-pro/text-to-image',
                           'edit' => 'alibaba/wan-2.7/image-edit', 'desc' => 'Wan desc' },
      'flux-2-pro'    => { 'provider' => 'flux', 't2i' => 'flux-2-pro',
                           'edit' => false, 'desc' => 'Flux desc' },
    },
  }.freeze

  def setup
    Settings.image_gen = Marshal.load(Marshal.dump(CATALOG))
    ImageGen::Catalog.reset!
  end

  def teardown
    Settings.image_gen = nil
    ImageGen::Catalog.reset!
  end

  def test_keys_and_default
    assert_equal %w[nano-banana-2 wan-2.7 flux-2-pro], ImageGen::Catalog.keys
    assert_equal 'nano-banana-2', ImageGen::Catalog.default_key
  end

  def test_resolve_key_valid_blank_invalid
    assert_equal 'wan-2.7',       ImageGen::Catalog.resolve_key('wan-2.7')
    assert_equal 'nano-banana-2', ImageGen::Catalog.resolve_key(nil)
    assert_equal 'nano-banana-2', ImageGen::Catalog.resolve_key('')
    assert_equal 'nano-banana-2', ImageGen::Catalog.resolve_key('does-not-exist')
  end

  def test_provider_for
    assert_equal 'atlas', ImageGen::Catalog.provider_for('wan-2.7')
    assert_equal 'flux',  ImageGen::Catalog.provider_for('flux-2-pro')
    # unknown key → default's provider
    assert_equal 'atlas', ImageGen::Catalog.provider_for('bogus')
  end

  def test_model_id_for_text_to_image
    assert_equal 'alibaba/wan-2.7-pro/text-to-image', ImageGen::Catalog.model_id_for('wan-2.7', :text_to_image)
    assert_equal 'google/nano-banana-2/text-to-image', ImageGen::Catalog.model_id_for('nano-banana-2', :text_to_image)
  end

  def test_model_id_for_edit_including_unsupported
    assert_equal 'google/nano-banana-2/edit', ImageGen::Catalog.model_id_for('nano-banana-2', :edit)
    assert_equal 'alibaba/wan-2.7/image-edit', ImageGen::Catalog.model_id_for('wan-2.7', :edit)
    # edit: false → nil (caller passes model:nil → adapter uses its default)
    assert_nil ImageGen::Catalog.model_id_for('flux-2-pro', :edit)
  end

  def test_edit_supported
    assert ImageGen::Catalog.edit_supported?('nano-banana-2')
    assert ImageGen::Catalog.edit_supported?('wan-2.7')
    refute ImageGen::Catalog.edit_supported?('flux-2-pro')
  end

  def test_enum_and_describe_options
    assert_equal %w[nano-banana-2 wan-2.7 flux-2-pro], ImageGen::Catalog.enum
    desc = ImageGen::Catalog.describe_options
    assert_match(/nano-banana-2 — NB2 desc/, desc)
    assert_match(/wan-2.7 — Wan desc/, desc)
    assert_match(/flux-2-pro — Flux desc/, desc)
  end

  def test_empty_catalog_is_safe
    Settings.image_gen = { 'provider' => 'atlas' } # no models / default_model
    ImageGen::Catalog.reset!
    assert_equal [], ImageGen::Catalog.enum
    assert_nil ImageGen::Catalog.default_key
    assert_equal '', ImageGen::Catalog.describe_options
    # resolve_key with no catalog falls back to (nil) default_key
    assert_nil ImageGen::Catalog.resolve_key('anything')
  end

  def test_memoization_and_reset
    assert_equal 3, ImageGen::Catalog.all.size
    # Mutate settings WITHOUT reset → memoized value unchanged
    Settings.image_gen = { 'models' => {} }
    assert_equal 3, ImageGen::Catalog.all.size
    ImageGen::Catalog.reset!
    assert_equal 0, ImageGen::Catalog.all.size
  end
end
