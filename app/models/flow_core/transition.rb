# frozen_string_literal: true

module FlowCore
  class Transition < FlowCore::ApplicationRecord
    self.table_name = "flow_core_transitions"

    FORBIDDEN_ATTRIBUTES = %i[workflow_id created_at updated_at].freeze unless const_defined?(:FORBIDDEN_ATTRIBUTES)

    belongs_to :generated_by,
               class_name: "FlowCore::Step", foreign_key: :generated_by_step_id,
               inverse_of: :generated_transitions, optional: true

    belongs_to :workflow, class_name: "FlowCore::Workflow"

    # NOTE: Place - out -> Transition - in -> Place
    has_many :input_arcs, -> { where(direction: :in) },
             class_name: "FlowCore::Arc", inverse_of: :transition, dependent: :destroy
    has_many :output_arcs, -> { where(direction: :out) },
             class_name: "FlowCore::Arc", inverse_of: :transition, dependent: :destroy

    has_many :input_places, through: :input_arcs, class_name: "FlowCore::Place", source: :place
    has_many :output_places, through: :output_arcs, class_name: "FlowCore::Place", source: :place

    has_one :trigger, class_name: "FlowCore::TransitionTrigger", dependent: :delete

    enum :output_token_create_strategy, { petri_net: 0, match_one_or_fallback: 1 }, suffix: :strategy

    enum :auto_finish_strategy, { disabled: 0, synchronously: 1 }, prefix: :auto_finish

    accepts_nested_attributes_for :trigger

    before_destroy :prevent_destroy
    after_create :reset_workflow_verification
    after_destroy :reset_workflow_verification

    def output_and_split?
      output_arcs.includes(:guards).all? { |arc| arc.guards.empty? }
    end

    def output_explicit_or_split?
      output_arcs.includes(:guards).select { |arc| arc.guards.any? } < output_arcs.size
    end

    def input_and_join?
      input_arcs.size > 1
    end

    def input_sequence?
      input_arcs.size == 1
    end

    def output_sequence?
      output_arcs.size == 1
    end

    def create_task_if_needed(token:)
      instance = token.instance
      candidate_tasks = instance.tasks.created.where(transition: self)

      # TODO: Is it possible that a input place has more than one free tokens? if YES we should handle it
      if candidate_tasks.empty?
        token.instance.tasks.create! transition: self, created_by_token: token
      end
    end

    def create_output_tokens_for(task)
      instance = task.instance
      arcs = output_arcs.includes(:place, :guards).to_a

      end_arc = arcs.find { |arc| arc.place.is_a? EndPlace }
      if end_arc
        if end_arc.guards.empty? || end_arc.guards.map { |guard| guard.permit? task }.reduce(&:&)
          instance.tokens.create! created_by_task: task, place: end_arc.place
          return
        end

        unless end_arc.fallback_arc?
          arcs.delete(end_arc)
        end
      end

      candidate_arcs =
        case output_token_create_strategy
        when "match_one_or_fallback"
          find_output_arcs_with_match_one_or_fallback_strategy(arcs, task)
        else
          find_output_arcs_with_petri_net_strategy(arcs, task)
        end

      if candidate_arcs.empty?
        # TODO: find a better way
        on_task_errored task, FlowCore::NoNewTokenCreated.new
        return
      end

      candidate_arcs.each do |arc|
        instance.tokens.create! created_by_task: task, place: arc.place
      end
    end

    def on_task_enable(task)
      trigger&.on_task_enable(task)
    end

    def on_task_finish(task)
      trigger&.on_task_finish(task)
    end

    def on_task_terminate(task)
      trigger&.on_task_terminate(task)
    end

    def on_task_errored(task, error)
      trigger&.on_task_errored(task, error)
    end

    def on_task_rescue(task)
      trigger&.on_task_rescue(task)
    end

    def on_task_suspend(task)
      trigger&.on_task_suspend(task)
    end

    def on_task_resume(task)
      trigger&.on_task_resume(task)
    end

    def can_destroy?
      workflow.instances.empty?
    end

    private

      def find_output_arcs_with_petri_net_strategy(arcs, task)
        arcs.select do |arc|
          arc.guards.empty? || arc.guards.map { |guard| guard.permit? task }.reduce(&:&)
        end
      end

      def find_output_arcs_with_match_one_or_fallback_strategy(arcs, task)
        fallback_arc = arcs.find(&:fallback_arc?)
        candidate_arcs = arcs.select do |arc|
          !arc.fallback_arc? && (arc.guards.empty? || arc.guards.map { |guard| guard.permit? task }.reduce(&:&))
        end

        [candidate_arcs.first || fallback_arc]
      end

      def reset_workflow_verification
        workflow.reset_workflow_verification!
      end

      def prevent_destroy
        unless can_destroy?
          raise FlowCore::ForbiddenOperation, "Found exists instance, destroy transition will lead serious corruption"
        end
      end
  end
end
