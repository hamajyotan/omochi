# Form object for creating a Quest from the Dashboard (title + first instruction).
class QuestForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :title, :string
  attribute :body, :string

  validates :title, presence: true, length: { maximum: 200 }
  validates :body, presence: true, length: { maximum: QuestInstruction::MAX_BODY_LENGTH }
end
