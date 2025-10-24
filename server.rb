require 'sinatra'
require 'json'
require 'time'
require_relative './lib/key_store'

set :bind, '0.0.0.0'
set :port, (ENV['PORT'] || 4567).to_i


expiry_seconds = (ENV['KEY_EXPIRY_SECONDS'] || 300).to_i
block_seconds  = (ENV['KEY_BLOCK_SECONDS']  || 60).to_i
poll_interval  = (ENV['KEY_POLL_INTERVAL']  || 1).to_f

KEY_STORE = KeyStore.new(
  expiry_seconds: expiry_seconds,
  block_seconds: block_seconds,
  poll_interval: poll_interval
)

# simple HTML index so visiting / shows a friendly page
get '/' do
  content_type 'text/html'
  <<~HTML
    <!doctype html>
    <html>
    <head><meta charset="utf-8"><title>API Key Server</title></head>
    <body style="font-family:system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial;">
      <h1>API Key Server</h1>
      <p>Use the API endpoints (JSON):</p>
      <ul>
        <li><code>POST /keys</code> — generate a key</li>
        <li><code>GET /keys/available</code> — get &amp; block a random available key</li>
        <li><code>POST /keys/:key/unblock</code> — unblock a key</li>
        <li><code>POST /keys/:key/keep_alive</code> — keep key alive</li>
        <li><code>DELETE /keys/:key</code> — delete key</li>
        <li><code>GET /stats</code> — safe O(1) stats (total / available / blocked)</li>
      </ul>
      <p>Try creating one with:<br>
        <code>curl -X POST http://localhost:4567/keys -d ''</code>
      </p>
    </body>
    </html>
  HTML
end

before do

  content_type 'application/json'
end

# GET /stats -> safe O(1) counts of keys
get '/stats' do
  KEY_STORE.stats.to_json
end

# POST /keys => generate key
post '/keys' do
  key = KEY_STORE.generate_key
  meta = KEY_STORE.info(key)
  status 201
  {
    key: key,
    expiry_at: Time.at(meta[:expiry]).utc.iso8601
  }.to_json
end

# GET /keys/available => serve a random available key and block it
get '/keys/available' do
  key = KEY_STORE.get_available_key
  if key.nil?
    status 404
    { error: 'no available key' }.to_json
  else
    meta = KEY_STORE.info(key)
    blocked_iso = meta[:blocked_until] ? Time.at(meta[:blocked_until]).utc.iso8601 : nil
    {
      key: key,
      blocked_until: blocked_iso
    }.to_json
  end
end

# POST /keys/:key/unblock => unblock a key (reset expiry)
post '/keys/:key/unblock' do
  key = params[:key]
  ok = KEY_STORE.unblock_key(key)
  halt 404,({ error: 'not found' }.to_json) unless ok
  status 200
  { status: 'unblocked' }.to_json
end

# DELETE /keys/:key => delete key permanently
delete '/keys/:key' do
  key = params[:key]
  ok = KEY_STORE.delete_key(key)
  halt 404,({ error: 'not found' }.to_json) unless ok
  status 200
  { status: 'deleted' }.to_json
end

# POST /keys/:key/keep_alive => keep the key alive (extend expiry)
post '/keys/:key/keep_alive' do
  key = params[:key]
  ok = KEY_STORE.keep_alive(key)
  halt 404,({ error: 'not found' }.to_json) unless ok
  status 200
  { status: 'kept_alive' }.to_json
end

# GET /keys/:key => info (safe, per-key; not O(n))
get '/keys/:key' do
  key = params[:key]
  meta = KEY_STORE.info(key)
  halt 404,({ error: 'not found' }.to_json) unless meta
  # convert timestamps to iso strings for readability
  resp = {
    expiry_at: Time.at(meta[:expiry]).utc.iso8601,
    blocked: meta[:blocked],
    blocked_until: meta[:blocked_until] ? Time.at(meta[:blocked_until]).utc.iso8601 : nil,
    deleted: meta[:deleted]
  }
  resp.to_json
end