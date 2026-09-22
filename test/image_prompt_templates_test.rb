require_relative 'test_helper'
require_relative '../lib/image_gen'

class ImagePromptTemplatesTest < Minitest::Test
  ADAPTERS = [
    ImageGen::AtlasAdapter,
    ImageGen::FluxAdapter,
    ImageGen::CloseRouterImgAdapter,
  ].freeze

  def test_all_adapters_use_the_shared_comedy_first_text_template
    ADAPTERS.each do |klass|
      assert_same ImageGen::PromptTemplates::TEXT_TO_IMAGE,
                  klass.allocate.prompt_template(:text_to_image), klass.name
    end

    template = ImageGen::PromptTemplates::TEXT_TO_IMAGE
    assert_includes template, 'ОДИН сильный визуальный гэг'
    assert_includes template, '100–220 слов'
    assert_includes template, 'Никаких заголовков'
    assert_includes template, 'не более 1–3'
  end

  def test_all_adapters_use_the_shared_direct_edit_template
    ADAPTERS.each do |klass|
      assert_same ImageGen::PromptTemplates::EDIT,
                  klass.allocate.prompt_template(:edit), klass.name
    end

    template = ImageGen::PromptTemplates::EDIT
    assert_includes template, 'Не заменяй запрошенное эвфемизмами'
    assert_includes template, 'Не скрывай запрошенное обрезкой'
    assert_includes template, '40–120 слов'
  end

  def test_adult_templates_forbid_inventing_minors
    assert_includes ImageGen::PromptTemplates::TEXT_TO_IMAGE, 'не выдумывай детей'
    assert_includes ImageGen::PromptTemplates::EDIT, 'не выдумывай несовершеннолетних'
  end
end
