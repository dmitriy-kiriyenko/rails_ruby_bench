# Initially based on Discourse's user_simulator script

require_relative "vendor/gabbler"

# Example options array passed into these functions
#options = {
#  :user_offset => 0,
#  :random_seed => 1234567890,
#  :delay => nil,
#  :iterations => 100,
#  :warmup_iterations => 0,
#  :port_num => 4567,
#  :worker_threads => 5,
#  :out_dir => "/tmp",
#}

def sentence
  @gabbler ||= Gabbler.new.tap do |gabbler|
    story = File.read(File.dirname(__FILE__) + "/alice.txt")
    gabbler.learn(story)
  end

  sentence = ""
  until sentence.length > 800 do
    sentence << @gabbler.sentence
    sentence << "\n"
  end
  sentence
end

ACTIONS = [:read_topic, :post_reply, :post_topic, :get_latest]  # Not active: :save_draft, :delete_reply. See below.

class DiscourseClient
  def initialize(options)
    @cookies = nil
    @csrf = nil
    @prefix = "http://localhost:#{options[:port_num]}"

    @last_topics = Topic.order('id desc').limit(10).pluck(:id)
    @last_posts = Post.order('id desc').limit(10).pluck(:id)
  end

  def get_csrf_token
    resp = RestClient.get "#{@prefix}/session/csrf.json"
    @cookies = resp.cookies
    @csrf = JSON.parse(resp.body)["csrf"]
  end

  def request(method, url, payload = nil)
    args = { :method => method, :url => "#{@prefix}#{url}", :cookies => @cookies, :headers => { "X-CSRF-Token" => @csrf } }
    args[:payload] = payload if payload
    begin
      resp = RestClient::Request.execute args
    rescue RestClient::Found => e  # 302 redirect
      resp = e.response
    rescue RestClient::Exception   # Any other RestClient failure
      STDERR.puts "Got exception when #{method.to_s.upcase}ing #{url.inspect}..."
      raise
    end
    @cookies = resp.cookies  # Maintain continuity of cookies
    resp
  end

  # Given the randomized parameters for an action, take that action.
  # See below for randomized parameter generation from the random
  # seed.
  def action_from_args(action_type, text, fp)
    case action_type
    when :read_topic
      # Read Topic
      topic_id = @last_topics[-1]
      request(:get, "/t/#{topic_id}.json?track_visit=true&forceLoad=true")
    when :save_draft
      # Save draft - currently not active, need to fix 403. Wrong topic ID?
      topic_id = @last_topics[-1]
      post_id = @last_posts[-1]  # Not fully correct
      draft_hash = { "reply" => text * 5, "action" => "edit", "title" => "Title of draft reply", "categoryId" => 11, "postId" => post_id, "archetypeId" => "regular", "metaData" => nil, "sequence" => 0 }
      request(:post, "/draft.json", "draft_key" => "topic_#{topic_id}", "data" => draft_hash.to_json)
    when :post_reply
      # Post reply
      request(:post, "/posts", "raw" => text * 5, "unlist_topic" => "false", "category" => "9", "topic_id" => topic_id, "is_warning" => "false", "archetype" => "regular", "typing_during_msecs" => "2900", "composer_open_duration_msecs" => "12114", "featured_link" => "", "nested_post" => "true")
      # TODO: request(:delete, "/draft.json", "draft_key" => "topic_XX", "sequence" => "0")
      # TODO: update @last_posts
    when :post_topic
      # Post new topic
      request(:post, "/posts", "raw" => "", "title" => text, "unlist_topic" => "false", "category" => "", "is_warning" => "false", "archetype" => "regular", "typing_duration_msecs" => "6300", "composer_open_duration_msecs" => "31885", "nested_post" => "true")
      # TODO: request(:delete, "/draft.json", "topic_id" => "topic_XX")
      # TODO: request(:get, "/t/#{topic_id}.json?track_visit=true&forceLoad=true")
      # TODO: update @last_topics
    when :delete_reply
      # Delete reply, currently not active, need to get correct Post ID
      request(:delete, "/posts/#{post_num}")
      request(:get, "/posts/#{post_num - 1}")
      # TODO: update @last_posts
    when :get_latest
      # Get latest
      request(:get, "/latest.json?order=default")
    else
      raise "Something is wrong! Illegal value: #{action_type}"
    end
  end
end

def log(s)
  print "[#{Process.pid}]: #{s}\n"
end

def time_actions(actions, user_offset, port_num)
  username = "admin#{user_offset}"

  log "Simulating activity for user #{username}"

  log "Getting Rails CSRF token..."
  client = DiscourseClient.new(port_num: port_num)
  client.get_csrf_token

  log "Logging in as #{username.inspect}... (not part of benchmark request time(s))"
  client.request :post, "/session", { "login" => username, "password" => "longpassword" }
  client.request :post, "/login", { "login" => username, "password" => "longpassword", "redirect" => "http://localhost:#{port_num}/" }

  times = []
  t_last = Time.now
  actions.each do |action|
    client.action_from_args *action
    current = Time.now
    times.push (current - t_last)
    t_last = current
  end
  times
end

def actions_for_iterations(num_iterations)
  (1..num_iterations).map { |i| [ ACTIONS.sample, sentence, rand() ] }
end

def multithreaded_actions(actions, worker_threads, port_num)
  output_mutex = Mutex.new
  output_times = []

  #actions = (1..iterations).map { |i| [ ACTIONS.sample, sentence, rand() ] }
  actions_per_thread = (actions.size + worker_threads - 1) / worker_threads  # Round up

  threads = (0..(worker_threads-1)).map do |offset|
    Thread.new do
      begin
        # Grab just this one thread's worth of actions
        my_actions = actions[ (actions_per_thread * offset) .. (actions_per_thread * (offset + 1) - 1) ]

        # Only a few warmup iterations with lots of load threads? In that case, rounding error can result
        # in a few "empty" threads at high offsets. In that case, you have "too many" threads - just
        # have the ones with no work assigned do nothing.
        unless my_actions == nil || my_actions.size == 0
          thread_times = time_actions(my_actions, offset, port_num)
          output_mutex.synchronize do
            output_times << thread_times
          end
        end
      rescue Exception => e
        STDERR.print "Exception in worker thread: #{e.message}\n#{e.backtrace.join("\n")}\n"
        raise e # Re-raise the exception
      end
    end
  end

  threads.each(&:join)
  output_times
end
