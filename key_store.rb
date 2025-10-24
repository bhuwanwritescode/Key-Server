require 'securerandom'
require 'thread'
require_relative 'min_heap'

# KeyStore: generates and manages keys with expiry, blocking, unblocking, deletion and keep-alive.
class KeyStore
  attr_reader :expiry_seconds, :block_seconds

  # expiry_seconds: lifetime before key is deleted (unless kept alive)
  # block_seconds: seconds a key is blocked when served and auto-releases after this
  # poll_interval: how often background thread checks heaps (seconds)
  def initialize(expiry_seconds: 5 * 60, block_seconds: 60, poll_interval: 1.0)
    @expiry_seconds = expiry_seconds.to_f
    @block_seconds = block_seconds.to_f
    @poll_interval = poll_interval.to_f

    @mutex = Mutex.new
    # key => { expiry:, blocked:, blocked_until:, deleted: }
    @keys = {}

    # available keys stored in array for O(1) random pick + swap-delete
    @available_keys = []     
    @available_index = {}   

    # heaps (timestamp, key)
    @expiry_heap = MinHeap.new
    @block_heap = MinHeap.new

    # O(1) count of blocked keys for stats
    @blocked_count = 0

    start_background_thread
  end

  # E1: Generate a new key with expiry
  def generate_key
    @mutex.synchronize do
      key = SecureRandom.hex(16)
      now = Time.now.to_f
      expiry = now + @expiry_seconds
      @keys[key] = { expiry: expiry, blocked: false, blocked_until: nil, deleted: false }
      add_to_available(key)
      @expiry_heap.push(expiry, key)
      key
    end
  end

  # E2: Get an available key (random), mark blocked (not served again), returns key or nil
  def get_available_key
    @mutex.synchronize do
      return nil if @available_keys.empty?
      idx = rand(@available_keys.size)
      key = @available_keys[idx]
      block_key(key)
      key
    end
  end

  # E3: Unblock a key (and reset its expiry)
  def unblock_key(key)
    @mutex.synchronize do
      meta = @keys[key]
      return false unless meta && !meta[:deleted]
      # If it is blocked, then we will remove block entry
      if meta[:blocked]
        meta[:blocked] = false
        meta[:blocked_until] = nil
        @block_heap.remove(key)
        @blocked_count -= 1 if @blocked_count > 0
        now = Time.now.to_f
        meta[:expiry] = now + @expiry_seconds
        @expiry_heap.update(key, meta[:expiry])
        add_to_available(key)
        return true
      end
      # already unblocked -> just refresh expiry
      now = Time.now.to_f
      meta[:expiry] = now + @expiry_seconds
      @expiry_heap.update(key, meta[:expiry])
      true
    end
  end

  # Delete a key immediately and purge
  def delete_key(key)
    @mutex.synchronize do
      meta = @keys[key]
      return false unless meta
      if meta[:blocked]
        @blocked_count -= 1 if @blocked_count > 0
      end
      meta[:deleted] = true
      remove_from_available(key)
      @expiry_heap.remove(key)
      @block_heap.remove(key)
      @keys.delete(key)
      true
    end
  end

  # Keep-alive: clients call to extend expiry
  def keep_alive(key)
    @mutex.synchronize do
      meta = @keys[key]
      return false unless meta && !meta[:deleted]
      now = Time.now.to_f
      meta[:expiry] = now + @expiry_seconds
      @expiry_heap.update(key, meta[:expiry])
      true
    end
  end

  # Debug/info for a single key (safe O(1))
  def info(key)
    @mutex.synchronize do
      meta = @keys[key]
      return nil unless meta
      { expiry: meta[:expiry], blocked: meta[:blocked], blocked_until: meta[:blocked_until], deleted: meta[:deleted] }
    end
  end

  # O(1) stats (safe to expose)
  def stats
    @mutex.synchronize do
      {
        total_keys: @keys.size,
        available: @available_keys.size,
        blocked: @blocked_count
      }
    end
  end

  private

  def add_to_available(key)
    return if @available_index.key?(key)
    idx = @available_keys.size
    @available_keys << key
    @available_index[key] = idx
  end

  # O(1) swap-delete removal from available array
  def remove_from_available(key)
    idx = @available_index[key]
    return unless idx
    last = @available_keys.last
    if last == key
      @available_keys.pop
      @available_index.delete(key)
      return
    end
    # move last into idx, update index map, pop
    @available_keys[idx] = last
    @available_index[last] = idx
    @available_keys.pop
    @available_index.delete(key)
  end

  def block_key(key)
    meta = @keys[key]
    return unless meta && !meta[:deleted] && !meta[:blocked]
    meta[:blocked] = true
    remove_from_available(key)
    now = Time.now.to_f
    blocked_until = now + @block_seconds
    meta[:blocked_until] = blocked_until
    @block_heap.push(blocked_until, key)
    @blocked_count += 1
  end

  # Background thread: processes expiry and block-release, using heaps (no O(n) per endpoint).
  def start_background_thread
    Thread.new do
      begin
        loop do
          now = Time.now.to_f
          @mutex.synchronize do
            while (top = @expiry_heap.peek) && top[0] <= now
              _, expired_key = @expiry_heap.pop
              meta = @keys[expired_key]
              next unless meta && !meta[:deleted]
              # purge expired key
              meta[:deleted] = true
              remove_from_available(expired_key)
              # ensure blocked count and block heap are cleaned
              if meta[:blocked]
                @blocked_count -= 1 if @blocked_count > 0
                @block_heap.remove(expired_key)
              end
              @keys.delete(expired_key)
            end

            # Process blocked keys whose block time expired => auto-release
            while (top = @block_heap.peek) && top[0] <= now
              _, releasing_key = @block_heap.pop
              meta = @keys[releasing_key]
              next unless meta && !meta[:deleted]
              if meta[:blocked]
                meta[:blocked] = false
                meta[:blocked_until] = nil
                @blocked_count -= 1 if @blocked_count > 0
                meta[:expiry] = now + @expiry_seconds
                @expiry_heap.update(releasing_key, meta[:expiry])
                add_to_available(releasing_key)
              end
            end
          end
          sleep @poll_interval
        end
      rescue => e
        # Log the error (replace with proper logging in production)
        puts "Background thread error: #{e.message}\n#{e.backtrace.join("\n")}"
        sleep 5  # Backoff to prevent tight loop on repeated failures
        retry    # Restart the loop
      end
    end
  end
end