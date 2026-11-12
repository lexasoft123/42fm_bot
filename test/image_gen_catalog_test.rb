require_relative 'test_helper'
require 'yaml'
LOGGER = Logger.new(IO::NULL) unless defined?(LOGGER)

# Settings.image_gen accessor (same stub the adapter test uses).
unless Settings.respond_to?(:image_gen)
  Settings.singleton_class.send(:define_method, :image_gen) { @image_gen }
  Settings.singleton_class.send(:define_method, :image_gen=) { |v| @image_gen = v }
end

require_relative '../lib/image_gen'

class ImageGenCatalogTest < Minitest::Test
  CATALOG = {
    'default_model' => 'qwen-image-3-pro',
    'models' => {
      'nano-banana-2' => { 'provider' => 'atlas', 't2i' => 'google/nano-banana-2/text-to-image',
                           'edit' => 'google/nano-banana-2/edit', 'multi_image' => true, 'desc' => 'NB2 desc' },
      'wan-2.7'       => { 'provider' => 'atlas', 't2i' => 'alibaba/wan-2.7-pro/text-to-image',
                           'edit' => 'alibaba/wan-2.7/image-edit', 'desc' => 'Wan desc' },
      'qwen-image-3-pro' => { 'provider' => 'atlas', 't2i' => 'qwen-image-3.0-pro/text-to-image',
                              'edit' => 'qwen-image-3.0-pro/edit', 'multi_image' => true, 'desc' => 'Qwen desc' },
      'gpt-image-2.5-sunburst' => { 'provider' => 'atlas', 't2i' => 'openai/gpt-image-2.5-sunburst/text-to-image',
                                    'edit' => 'openai/gpt-image-2.5-sunburst/edit', 'multi_image' => true, 'desc' => 'Sunburst desc' },
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

  def test_specific_model_name_wins_over_ambiguous_family
    Settings.image_gen['models']['nano-banana-pro'] = { 'provider' => 'closerouter', 't2i' => 'pro', 'edit' => 'edit' }
    ImageGen::Catalog.reset!
    assert_equal 'nano-banana-pro', ImageGen::Catalog.requested_key('Сделай через Nano Banana Pro')
    assert_equal 'nano-banana-2', ImageGen::Catalog.requested_key('Nano Banana 2')
    assert_nil ImageGen::Catalog.requested_key('nano')
    assert_nil ImageGen::Catalog.requested_key('swan')
    assert_equal 'gpt-image-2.5-sunburst', ImageGen::Catalog.requested_key('через Sunburst')
  end

  def test_positive_model_wins_over_excluded_specific_name
    directive = 'Нарисуй кота в Qwen, не используй GPT Image 2.5 Sunburst'
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.requested_key(directive)
    assert_equal ['gpt-image-2.5-sunburst'], ImageGen::Catalog.excluded_keys(directive)
    assert_nil ImageGen::Catalog.requested_key('Нарисуй кота, не используй Sunburst')
    assert_equal ['gpt-image-2.5-sunburst'], ImageGen::Catalog.excluded_keys('Нарисуй кота, не используй Sunburst')
    assert_equal 'wan-2.7', ImageGen::Catalog.requested_key('Не Qwen, а Wan')
    assert_nil ImageGen::Catalog.requested_key('Не используй Wan и Qwen')
    assert_nil ImageGen::Catalog.requested_key('swan')
  end

  def test_exclusion_scope_covers_coordinated_lists_but_ends_at_new_instruction
    text = 'Нарисуй кота без Wan, Flux и Qwen'
    assert_nil ImageGen::Catalog.requested_key(text)
    assert_equal %w[wan-2.7 flux-2-pro qwen-image-3-pro], ImageGen::Catalog.excluded_keys(text)
    directive = 'Без Wan, Flux и Qwen, используй GPT Image 2.5 Sunburst'
    assert_equal 'gpt-image-2.5-sunburst', ImageGen::Catalog.requested_key(directive)
    assert_equal %w[wan-2.7 flux-2-pro qwen-image-3-pro], ImageGen::Catalog.excluded_keys(directive)
    assert_equal 'gpt-image-2.5-sunburst', ImageGen::Catalog.requested_key('без Wan и Flux, но используй Sunburst')
    assert_equal 'gpt-image-2.5-sunburst', ImageGen::Catalog.requested_key('without Wan, Flux, use Sunburst')
  end

  def test_contrast_ends_exclusion_scope
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.requested_key('not Flux but Qwen')
    assert_equal ['flux-2-pro'], ImageGen::Catalog.excluded_keys('not Flux but Qwen')
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.requested_key('не Flux, а Qwen')
    assert_equal ['flux-2-pro'], ImageGen::Catalog.excluded_keys('не Flux, а Qwen')
  end

  def test_visual_exclusions_do_not_exclude_a_later_selected_model
    ['Нарисуй кота без шляпы через Sunburst', 'Кот без шляпы, через Sunburst',
     'Draw a cat without a hat using Sunburst'].each do |directive|
      assert_equal 'gpt-image-2.5-sunburst', ImageGen::Catalog.requested_key(directive)
      assert_empty ImageGen::Catalog.excluded_keys(directive)
    end
    assert_equal ['wan-2.7'], ImageGen::Catalog.excluded_keys('нарисуй без модели Wan')
    assert_equal ['flux-2-pro'], ImageGen::Catalog.excluded_keys('не используй модель Flux')
  end

  def test_keys_and_default
    assert_equal %w[nano-banana-2 wan-2.7 qwen-image-3-pro gpt-image-2.5-sunburst flux-2-pro], ImageGen::Catalog.keys
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.default_key
  end

  def test_resolve_key_valid_blank_invalid
    assert_equal 'wan-2.7',       ImageGen::Catalog.resolve_key('wan-2.7')
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.resolve_key(nil)
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.resolve_key('')
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.resolve_key('does-not-exist')
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
    assert_equal 'qwen-image-3.0-pro/text-to-image', ImageGen::Catalog.model_id_for('qwen-image-3-pro', :text_to_image)
    assert_equal 'openai/gpt-image-2.5-sunburst/text-to-image', ImageGen::Catalog.model_id_for('gpt-image-2.5-sunburst', :text_to_image)
  end

  def test_model_id_for_edit_including_unsupported
    assert_equal 'google/nano-banana-2/edit', ImageGen::Catalog.model_id_for('nano-banana-2', :edit)
    assert_equal 'alibaba/wan-2.7/image-edit', ImageGen::Catalog.model_id_for('wan-2.7', :edit)
    assert_equal 'qwen-image-3.0-pro/edit', ImageGen::Catalog.model_id_for('qwen-image-3-pro', :edit)
    assert_equal 'openai/gpt-image-2.5-sunburst/edit', ImageGen::Catalog.model_id_for('gpt-image-2.5-sunburst', :edit)
    # edit: false → nil (caller passes model:nil → adapter uses its default)
    assert_nil ImageGen::Catalog.model_id_for('flux-2-pro', :edit)
  end

  def test_edit_supported
    assert ImageGen::Catalog.edit_supported?('nano-banana-2')
    assert ImageGen::Catalog.edit_supported?('wan-2.7')
    refute ImageGen::Catalog.edit_supported?('flux-2-pro')
  end

  def test_multi_image
    assert ImageGen::Catalog.multi_image?('nano-banana-2'), 'flagged multi_image: true'
    assert ImageGen::Catalog.multi_image?('qwen-image-3-pro'), 'Qwen supports up to three references'
    assert ImageGen::Catalog.multi_image?('gpt-image-2.5-sunburst'), 'Sunburst supports multiple references'
    refute ImageGen::Catalog.multi_image?('wan-2.7'),       'no flag → single image'
    refute ImageGen::Catalog.multi_image?('flux-2-pro')
    # unknown key resolves to the (capable) default
    assert ImageGen::Catalog.multi_image?('bogus')
  end

  def test_multi_image_default_key
    # Default (Qwen) is itself capable → returned as-is.
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.multi_image_default_key
    # Default flipped to a single-image model → falls back to first capable key.
    Settings.image_gen = Marshal.load(Marshal.dump(CATALOG)).merge('default_model' => 'wan-2.7')
    ImageGen::Catalog.reset!
    assert_equal 'nano-banana-2', ImageGen::Catalog.multi_image_default_key
  end

  def test_shipped_config_defaults_and_legacy_atlas_models_are_qwen
    common = YAML.load_file(File.expand_path('../config/settings.common.yml', __dir__))
    Settings.image_gen = common.fetch('image_gen')
    ImageGen::Catalog.reset!

    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.default_key
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.resolve_key(nil)
    assert_equal 'qwen-image-3-pro', ImageGen::Catalog.resolve_key('unknown-model')

    atlas = Settings.image_gen.dig('providers', 'atlas')
    assert_equal 'qwen-image-3.0-pro/text-to-image', atlas['text_to_image_model']
    assert_equal 'qwen-image-3.0-pro/edit', atlas['image_edit_model']
  end

  def test_enum_and_describe_options
    assert_equal %w[nano-banana-2 wan-2.7 qwen-image-3-pro gpt-image-2.5-sunburst flux-2-pro], ImageGen::Catalog.enum
    desc = ImageGen::Catalog.describe_options
    assert_match(/nano-banana-2 — NB2 desc/, desc)
    assert_match(/wan-2.7 — Wan desc/, desc)
    assert_match(/qwen-image-3-pro — Qwen desc/, desc)
    assert_match(/gpt-image-2.5-sunburst — Sunburst desc/, desc)
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
    assert_equal 5, ImageGen::Catalog.all.size
    # Mutate settings WITHOUT reset → memoized value unchanged
    Settings.image_gen = { 'models' => {} }
    assert_equal 5, ImageGen::Catalog.all.size
    ImageGen::Catalog.reset!
    assert_equal 0, ImageGen::Catalog.all.size
  end
end
