# Stubs for the Assistants HTTP API, and the interrupts a paused run reports, shared by the
# Assistants and review specs.
module AssistantsHelpers
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  # Stubs `method` on `url` to answer `body` as JSON, only for a request sending `request_body`
  # when one is given.
  def stub_json(method, url, body, status: 200, request_body: nil)
    stub = stub_request(method, url)
    stub = stub.with(body: request_body.to_json) unless request_body.nil?
    stub.to_return(status:, body: body.to_json, headers: JSON_HEADERS)
  end

  # A `__reply__` pause holding `content`.
  def reply_interrupt_for(content, id: "interrupt-reply", allowed: %w[approve edit reject], description: nil)
    action_request = { "name" => "__reply__", "args" => { "content" => content }, "description" => description }
    interrupt_for([action_request.compact], allowed: { "__reply__" => allowed }, id:)
  end

  # A pause on one call to the tool `name` with `args`.
  def tool_interrupt_for(name, args, id: "interrupt-tools", allowed: %w[approve reject])
    interrupt_for([{ "name" => name, "args" => args }], allowed: { name => allowed }, id:)
  end

  def interrupt_for(action_requests, allowed:, id: nil)
    review_configs = allowed.map { |name, decisions| { "action_name" => name, "allowed_decisions" => decisions } }
    { "id" => id, "value" => { "action_requests" => action_requests, "review_configs" => review_configs } }.compact
  end
end

# A thread of the client under test, and stubs for reading it while it is paused and for resuming
# it. Expects `base_url` from the including group.
RSpec.shared_context "with an Assistants thread" do
  let(:thread_id) { "thread-456" }
  let(:thread_url) { "#{base_url}/threads/#{thread_id}" }
  let(:state_url) { "#{base_url}/threads/#{thread_id}/state" }
  let(:run_url) { "#{base_url}/threads/#{thread_id}/runs/wait" }

  def stub_paused_thread(messages:, interrupt:, status: "interrupted")
    stub_json(:get, thread_url, { "thread_id" => thread_id, "status" => status })
    stub_json(:get, state_url, { "values" => { "messages" => messages }, "interrupts" => [interrupt].compact })
  end

  # A resume Assistants accepted, with the run it created named in the wait's Content-Location.
  def stub_resume(body, run_id: "run-mine")
    stub_request(:post, run_url).to_return(
      status: 200, body: body.to_json,
      headers: AssistantsHelpers::JSON_HEADERS.merge("Content-Location" => "/threads/#{thread_id}/runs/#{run_id}")
    )
  end

  # The thread's state as it reads before the resume, then after it.
  def stub_states(before, after)
    stub_request(:get, state_url)
      .to_return(status: 200, body: before.to_json, headers: AssistantsHelpers::JSON_HEADERS)
      .then.to_return(status: 200, body: after.to_json, headers: AssistantsHelpers::JSON_HEADERS)
  end
end

RSpec.configure do |config|
  config.include AssistantsHelpers
end
