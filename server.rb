require 'json'
require 'net/http'
require 'uri'
require 'webrick'

ROOT = File.expand_path(__dir__)
UI_ROOT = File.join(ROOT, 'ui')
AI_PROVIDER = ENV.fetch('AI_PROVIDER', 'ollama').downcase
OLLAMA_BASE_URL = URI(ENV.fetch('OLLAMA_BASE_URL', 'http://127.0.0.1:11434'))
OPENAI_BASE_URL = URI(ENV.fetch('OPENAI_BASE_URL', 'https://api.openai.com/v1'))
MODEL = ENV.fetch('AI_MODEL', ENV.fetch('OLLAMA_MODEL', 'llama3.2:3b'))
OPENAI_API_KEY = ENV['OPENAI_API_KEY'] || ENV['AI_API_KEY']
ASSISTANT_INSTRUCTIONS = 'Your name is Jarvis 2.O. When asked your name, say Jarvis 2.O. You are a helpful, friendly voice-first personal assistant.'

def join_api_uri(base_url, path)
  base = base_url.dup
  base_path = base.path.to_s.sub(%r{/*\z}, '')
  relative_path = path.to_s.sub(%r{\A/+}, '')
  joined = [base_path, relative_path].reject(&:empty?).join('/')
  base.path = joined.empty? ? '/' : joined.start_with?('/') ? joined : "/#{joined}"
  base.query = nil
  base.fragment = nil
  base
end

def http_json_request(method, uri, body = nil, bearer_token = nil)
  request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  request['Accept'] = 'application/json'
  request['Authorization'] = "Bearer #{bearer_token}" if bearer_token && !bearer_token.empty?
  request.body = JSON.generate(body) if body

  Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 300) do |http|
    http.request(request)
  end
end

def ollama_request(method, path, body = nil)
  uri = join_api_uri(OLLAMA_BASE_URL, path)
  http_json_request(method, uri, body)
end

def openai_request(method, path, body = nil)
  uri = join_api_uri(OPENAI_BASE_URL, path)
  http_json_request(method, uri, body, OPENAI_API_KEY)
end

def ollama_models
  response = ollama_request(:get, '/api/tags')
  raise "Ollama returned HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body).fetch('models', []).filter_map do |model|
    case model
    when String
      model.strip
    when Hash
      (model['name'] || model['model']).to_s.strip
    end
  end.reject(&:empty?)
end

def model_installed?(models)
  models.any? { |name| name.to_s.strip == MODEL.to_s.strip }
end

def extract_openai_text(payload)
  choices = payload['choices']
  return '' unless choices.is_a?(Array) && !choices.empty?

  first_choice = choices.first
  message = first_choice['message']
  return '' unless message.is_a?(Hash)

  content = message['content']
  case content
  when Array
    content.filter_map do |part|
      next unless part.is_a?(Hash)

      text = part['text']
      text.is_a?(String) ? text : nil
    end.join
  when String
    content
  else
    ''
  end
end

def json_response(response, status, payload)
  response.status = status
  response['Content-Type'] = 'application/json; charset=utf-8'
  response['Cache-Control'] = 'no-store'
  response.body = JSON.generate(payload)
end

server = WEBrick::HTTPServer.new(
  BindAddress: ENV.fetch('HOST', '0.0.0.0'),
  Port: Integer(ENV.fetch('PORT', '8000')),
  DocumentRoot: UI_ROOT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

server.mount_proc('/api/status') do |request, response|
  if request.request_method != 'GET' || request.path != '/api/status'
    json_response(response, 404, error: 'Not found')
    next
  end

  begin
    if AI_PROVIDER == 'openai'
      configured = !OPENAI_API_KEY.to_s.empty?
      json_response(response, 200, configured: configured, provider: 'OpenAI-compatible', model: MODEL, models: [MODEL],
                    error: configured ? nil : 'Set OPENAI_API_KEY and OPENAI_BASE_URL to use a hosted AI model.')
      next
    end

    models = ollama_models
    configured = model_installed?(models)
    json_response(response, 200, configured: configured, provider: 'Ollama', model: MODEL, models: models)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
    warn "AI status check failed: #{error.class}"
    json_response(response, 200, configured: false, provider: AI_PROVIDER == 'openai' ? 'OpenAI-compatible' : 'Ollama', model: MODEL, models: [],
                  error: AI_PROVIDER == 'openai' ? 'Could not reach the configured AI provider.' : 'Ollama is not running. Install Ollama, start it, then download the model shown in setup.')
  rescue JSON::ParserError, KeyError, TypeError => error
    warn "Could not parse AI model list: #{error.class}"
    json_response(response, 502, error: 'The configured AI provider returned an unreadable model list.')
  end
end

server.mount_proc('/api/configure') do |request, response|
  unless request.request_method == 'POST' && request.path == '/api/configure'
    json_response(response, 404, error: 'Not found')
    next
  end

  begin
    if AI_PROVIDER == 'openai'
      if OPENAI_API_KEY.to_s.empty?
        json_response(response, 400, error: 'Set OPENAI_API_KEY and OPENAI_BASE_URL before deploying this app to a public URL.')
      else
        json_response(response, 200, configured: true, provider: 'OpenAI-compatible', model: MODEL, models: [MODEL])
      end
      next
    end

    models = ollama_models
    if model_installed?(models)
      json_response(response, 200, configured: true, provider: 'Ollama', model: MODEL, models: models)
    else
      json_response(response, 400, error: "Model #{MODEL} is not installed. Run `ollama pull #{MODEL}` and try again.")
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
    warn "AI connection check failed: #{error.class}"
    json_response(response, 502, error: AI_PROVIDER == 'openai' ? 'Could not reach the configured AI provider.' : 'Could not reach Ollama. Install it and make sure the local Ollama app is running.')
  rescue JSON::ParserError, KeyError, TypeError => error
    warn "Could not parse AI model list: #{error.class}"
    json_response(response, 502, error: 'The configured AI provider returned an unreadable model list.')
  end
end

server.mount_proc('/api/chat') do |request, response|
  unless request.request_method == 'POST' && request.path == '/api/chat'
    json_response(response, 404, error: 'Not found')
    next
  end

  begin
    payload = JSON.parse(request.body.to_s)
  rescue JSON::ParserError
    json_response(response, 400, error: 'Invalid JSON request.')
    next
  end

  messages = payload.is_a?(Hash) ? payload['messages'] : nil
  valid_messages = messages.is_a?(Array) && messages.length.between?(1, 40) &&
    messages.all? do |message|
      message.is_a?(Hash) &&
        %w[user assistant].include?(message['role']) &&
        message['content'].is_a?(String) &&
        message['content'].bytesize.between?(1, 8000)
    end
  unless valid_messages
    json_response(response, 400, error: 'Send between 1 and 40 non-empty user or assistant messages.')
    next
  end

  begin
    upstream = if AI_PROVIDER == 'openai'
                 openai_request(:post, '/chat/completions', {
                   model: MODEL,
                   messages: [{ role: 'system', content: ASSISTANT_INSTRUCTIONS }] + messages,
                   temperature: 0.7
                 })
               else
                 ollama_request(:post, '/api/chat', {
                   model: MODEL,
                   messages: [{ role: 'system', content: ASSISTANT_INSTRUCTIONS }] + messages,
                   stream: false
                 })
               end

    unless upstream.is_a?(Net::HTTPSuccess)
      provider_label = AI_PROVIDER == 'openai' ? 'OpenAI-compatible API' : 'Ollama'
      warn "#{provider_label} chat request failed with HTTP #{upstream.code}"
      json_response(response, 502, error: "#{provider_label} could not complete that request (HTTP #{upstream.code}).")
      next
    end

    result = JSON.parse(upstream.body)
    text = if AI_PROVIDER == 'openai'
             extract_openai_text(result)
           else
             result.fetch('message', {}).fetch('content', '').to_s
           end

    if text.to_s.empty?
      json_response(response, 502, error: 'The AI provider returned an empty response. Please try again.')
    else
      json_response(response, 200, reply: text)
    end
  rescue JSON::ParserError, KeyError, TypeError => error
    warn "Could not parse AI chat response: #{error.class}"
    json_response(response, 502, error: 'The AI provider returned an unreadable response. Please try again.')
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
    warn "AI chat request failed: #{error.class}"
    json_response(response, 502, error: 'Could not reach the configured AI provider. Check the deployment environment variables and the provider status.')
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
server.start
