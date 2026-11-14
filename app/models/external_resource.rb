# A resource on an external platform (Slack thread, GitHub issue, ...) that is
# associated with a Quest. The identity is scoped by platform / type / scope so
# that the same external ID in different workspaces or repositories never collides.
class ExternalResource < ApplicationRecord
  PLATFORMS = %w[slack github].freeze

  belongs_to :quest

  validates :platform, inclusion: { in: PLATFORMS }
  validates :resource_type, :scope_key, :external_id, presence: true
  validates :external_id, uniqueness: { scope: %i[platform resource_type scope_key] }
  validates :url, format: { with: /\Ahttps:\/\/\S+\z/ }, allow_blank: true

  def self.identity(platform:, resource_type:, scope_key:, external_id:)
    find_by(platform:, resource_type:, scope_key:, external_id:)
  end
end
