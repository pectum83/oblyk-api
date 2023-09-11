# frozen_string_literal: true

class ContestRanking
  DIVISION = 'division'
  ATTEMPTS_TO_TOP = 'attempts_to_top'
  ZONE_AND_TOP_REALISED = 'zone_and_top_realised'
  ATTEMPTS_TO_ONE_ZONE_AND_TOP = 'attempts_to_one_zone_and_top'
  ATTEMPTS_TO_TWO_ZONES_AND_TOP = 'attempts_to_two_zones_and_top'
  HIGHEST_HOLD = 'highest_hold'

  RANKING_TYPE_LIST = [
    DIVISION,
    ATTEMPTS_TO_TOP,
    ZONE_AND_TOP_REALISED,
    ATTEMPTS_TO_ONE_ZONE_AND_TOP,
    ATTEMPTS_TO_TWO_ZONES_AND_TOP,
    HIGHEST_HOLD
  ].freeze

  RANKING_UNITS = {
    DIVISION => %w[pts],
    ATTEMPTS_TO_TOP => %w[pts],
    ZONE_AND_TOP_REALISED => %w[top zone]
  }.freeze

  attr_accessor :ascents, :step, :category, :genre

  def initialize(step, category, genre)
    self.step = step
    self.category = category
    self.genre = genre

    self.ascents = ContestParticipantAscent.joins(:contest_participant, contest_route: :contest_route_group)
                                           .where(contest_participants: { contest_category_id: category.id })
                                           .where(contest_routes: { disabled_at: nil })
                                           .where(contest_route_groups: { contest_stage_step_id: step.id })

    self.ascents = ascents.where(contest_participants: { genre: genre }) unless category.unisex
    self.ascents = ascents.where(realised: true) if step.ranking_type == DIVISION
  end

  def scores(ascent_id)
    current_ascent = ascents.find { |ascent| ascent.id == ascent_id }
    no_score = { value: nil, details: ['NR'] }

    return no_score if current_ascent.blank?

    case step.ranking_type
    when DIVISION
      point = 1000 / ascents.count { |ascent| ascent.contest_route_id == current_ascent.contest_route_id }
      {
        value: point,
        details: [point]
      }
    when ATTEMPTS_TO_TOP
      point = 10 - (current_ascent.top_attempt - 1)
      {
        value: point,
        details: [point]
      }
    when ZONE_AND_TOP_REALISED
      top = current_ascent.top_attempt&.positive? || false
      zone = current_ascent.zone_1_attempt&.positive? || false
      value = 0
      value = 1.001 if top
      value = 0.001 if !top && zone
      {
        value: value,
        details: [top, zone]
      }
    else
      no_score
    end
  end

  def participant_scores(participant_id)
    value = nil
    details = nil

    ascents.each do |ascent|
      next if ascent.contest_participant_id != participant_id

      ascent_scores = scores(ascent.id)
      ascent_value = ascent_scores[:value]

      next unless ascent_scores[:value]

      value ||= 0
      value += ascent_value

      if [DIVISION, ATTEMPTS_TO_TOP].include? step.ranking_type
        details ||= [0]
        details[0] += ascent_value if ascent_value.present?
      elsif step.ranking_type == ZONE_AND_TOP_REALISED
        details ||= [0, 0]
        if ascent_value.present?
          details[0] += 1 if ascent_scores[:details].first
          details[1] += 1 if ascent_scores[:details].second
        end
      end
    end
    { value: value, details: details, units: RANKING_UNITS[step.ranking_type] }
  end
end