# 初始化测试文件模板

RSpec.describe EXAMPLE_CLASS do
  subject(:instance) { EXAMPLE_CLASS.new }

  describe '#example_method' do
    context 'when condition_a' do
      it 'should return expected_value' do
        expect(instance.example_method).to eq(:expected_value)
      end
    end

    context 'when condition_b' do
      it 'should handle edge_case' do
        expect { instance.example_method }.not_to raise_error
      end
    end
  end
end
