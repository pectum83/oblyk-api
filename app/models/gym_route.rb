# frozen_string_literal: true

class GymRoute < ApplicationRecord
  include AttachmentResizable
  include StripTagable

  has_one_attached :picture
  has_one_attached :thumbnail
  belongs_to :gym_sector, optional: true
  belongs_to :gym_grade_line, optional: true
  has_one :gym_space, through: :gym_sector
  has_one :gym, through: :gym_sector
  has_many :videos, as: :viewable
  has_many :ascent_gym_routes
  has_many :gym_route_openers
  has_many :gym_openers, through: :gym_route_openers

  delegate :feed_parent_id, to: :gym
  delegate :feed_parent_type, to: :gym
  delegate :feed_parent_object, to: :gym

  validates :opened_at, presence: true
  validates :gym_grade_line, presence: true, if: proc { |obj| obj.gym_sector.gym_grade.need_grade_line? }
  validates :climbing_type, inclusion: { in: Climb::GYM_LIST }
  validates :height, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :validate_sections

  validates :picture, blob: { content_type: :image }, allow_nil: true
  validates :thumbnail, blob: { content_type: :image }, allow_nil: true

  before_validation :format_route_section
  before_save :historize_grade_gap
  before_save :historize_sections_count

  scope :dismounted, -> { where.not(dismounted_at: nil) }
  scope :mounted, -> { where(dismounted_at: nil) }

  def gym_grade
    gym_grade_line&.gym_grade || gym_sector.gym_grade
  end

  def calculated_point
    case gym_grade.point_system_type
    when 'fix'
      points
    when 'divisible'
      ascents_count = self.ascents_count&.positive? ? self.ascents_count : 1
      1000 / ascents_count
    else
      nil
    end
  end

  def points_to_s
    calculated_point
  end

  def grade_to_s
    return '' unless gym_grade.difficulty_by_grade?

    if sections_count > 1
      sections_array = []
      sections.each do |section|
        sections_array << section['grade']
      end
      sections_array.join(', ')
    else
      min_grade_text
    end
  end

  def tags
    tags = []
    sections.each do |section|
      tags += section['tags']
    end
    tags
  end

  def mounted?
    dismounted_at.blank?
  end

  def dismounted?
    dismounted_at.present?
  end

  def dismount!
    self.dismounted_at = Time.zone.now
    save
  end

  def mount!
    self.dismounted_at = nil
    save
  end

  def picture_large_url
    resize_attachment picture, '700x700'
  end

  def thumbnail_url
    resize_attachment thumbnail, '300x300'
  end

  def app_path
    "#{ENV['OBLYK_APP_URL']}/gyms/#{gym.id}/#{gym.slug_name}/spaces/#{gym_space.id}/#{gym_space.slug_name}?route=#{id}"
  end

  def short_app_path
    "#{ENV['OBLYK_APP_URL']}/gr/#{gym.id}-#{id}"
  end

  def hold_gradiant
    gradiant(hold_colors, fluid: true)
  end

  def tag_gradiant
    gradiant(tag_colors, fluid: false)
  end

  def update_form_ascents!
    ascent_count = 0
    note_count = nil
    sum_note = nil

    ascent_gym_routes.each do |ascent|
      if ascent.ascent_status != 'project'
        ascent_count ||= 0
        ascent_count += 1
      end

      next unless ascent.note.present?

      note_count ||= 0
      sum_note ||= 0
      note_votes ||= {}
      note_votes[ascent.note] ||= { count: 0 }
      note_count += 1
      note_votes[ascent.note][:count] += 1
      sum_note += ascent.note
    end

    self.note = note_count ? sum_note / note_count : nil
    self.note_count = note_count
    self.ascents_count = ascent_count
    save
  end

  def summary_to_json
    Rails.cache.fetch("#{cache_key_with_version}/summary_gym_route", expires_in: 1.month) do
      {
        id: id,
        name: name,
        height: height,
        description: description,
        openers: gym_openers.map(&:summary_to_json),
        gym_opener_ids: gym_openers.map(&:id),
        opened_at: opened_at,
        dismounted_at: dismounted_at,
        polyline: polyline,
        hold_colors: hold_colors,
        tag_colors: tag_colors,
        sections: sections,
        grade_value_appreciation: grade_value_appreciation,
        note: note,
        note_count: note_count,
        ascents_count: ascents_count,
        sections_count: sections_count,
        gym_sector_id: gym_sector_id,
        gym_grade_line_id: gym_grade_line_id,
        points: points,
        dismounted: dismounted?,
        points_to_s: points_to_s,
        grade_to_s: grade_to_s,
        thumbnail: thumbnail.attached? ? thumbnail_url : nil,
        gym_sector_name: gym_sector.name,
        grade_gap: {
          max_grade_value: max_grade_value,
          min_grade_value: min_grade_value,
          max_grade_text: max_grade_text,
          min_grade_text: min_grade_text
        },
        gym_space: {
          id: gym_space.id,
          slug_name: gym_space.slug_name,
          name: gym_space.name
        },
        gym_sector: {
          id: gym_sector_id,
          name: gym_sector&.name
        },
        gym: {
          id: gym.id,
          slug_name: gym.slug_name
        }
      }
    end
  end

  def detail_to_json
    summary_to_json.merge(
      {
        picture: picture.attached? ? picture_large_url : nil,
        video_count: videos.count,
        gym_sector: gym_sector.summary_to_json,
        history: {
          created_at: created_at,
          updated_at: updated_at
        }
      }
    )

  end

  private

  def format_route_section
    new_sections = []
    single_pitch = sections.count == 1

    sections.each do |section|
      section_height = section['height'].present? ? Integer(section['height']) : nil
      new_sections << {
        climbing_type: single_pitch ? climbing_type : section['climbing_type'] || climbing_type,
        description: !single_pitch ? section['description'] : nil,
        grade: Grade.clean_grade(section['grade']),
        grade_value: Grade.to_value(section['grade']),
        height: single_pitch ? height : section_height,
        points: single_pitch ? points : section['points'],
        tags: section['tags']
      }
    end
    self.sections = new_sections
  end

  def historize_grade_gap
    max_grade_value = nil
    max_grade_text = nil
    min_grade_value = nil
    min_grade_text = nil

    sections.each do |section|
      next unless section['grade']

      max_grade_text = section['grade'] if max_grade_value.nil? || section['grade_value'] > max_grade_value
      max_grade_value = section['grade_value'] if max_grade_value.nil? || section['grade_value'] > max_grade_value

      min_grade_text = section['grade'] if min_grade_value.nil? || section['grade_value'] < min_grade_value
      min_grade_value = section['grade_value'] if min_grade_value.nil? || section['grade_value'] < min_grade_value
    end

    self.max_grade_text = max_grade_text
    self.min_grade_text = min_grade_text
    self.max_grade_value = max_grade_value
    self.min_grade_value = min_grade_value
  end

  def historize_sections_count
    self.sections_count =  sections.count
  end

  def validate_sections
    sections.each do |section|
      # valid types
      errors.add(:grade, I18n.t('activerecord.errors.messages.inclusion')) if section['grade'].present? && !Grade.valid?(section['grade'])

      # Valid numerics
      errors.add(:height, I18n.t('activerecord.errors.messages.greater_than')) if section['height'].present? && Integer(section['height']).negative?
    end
  end

  def gradiant(colors, fluid: true)
    number_of_color = colors.size
    gradiant = []
    if number_of_color == 1
      gradiant << {  color: colors[0], offset: 0 }
      gradiant << { color: colors[0], offset: 100 }
    else
      index = 0
      colors.each do |color|
        if fluid
          gradiant << { color: color, offset: 100 / (number_of_color - 1) * index }
        else
          gradiant << { color: color, offset: 100 / number_of_color * index }
          gradiant << { color: color, offset: 100 / number_of_color * (index + 1) }
          index += 1
        end
      end
    end
    gradiant
  end
end
