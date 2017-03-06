# kenna-asset-tagger
require 'rest-client'
require 'json'
require 'csv'
require 'ipaddr'
require 'thread'
require 'monitor'

@token = ARGV[0]
@csv_file = ARGV[1] #source data
@tag_column_file = ARGV[2] #tag meta data - column from source file and tag prefix
@search_field = ARGV[3] #field to use first for asset match ip_address or hostname
@ip_address = ARGV[4] #column name in source file which holds the search field data or empty string
@hostname = ARGV[5] #column name in source file which holds the hostname data or empty string
ARGV.length == 7 ? @priority_column = ARGV[6] : @priority_column = nil #column that holds priority setting


@asset_api_url = 'https://api.kennasecurity.com/assets'
@search_url = @asset_api_url + '/search?q='
@headers = {'content-type' => 'application/json', 'X-Risk-Token' => @token, 'accept' => 'application/json'}
@debug = false
@max_retries = 5

# Encoding characters
@enc_colon = "%3A"
@enc_dblquote = "%22"
@enc_space = "%20"

def is_ip?(str)
  !!IPAddr.new(str) rescue false
end

def build_ip_url(ipstring)
  puts "building ip url" if @debug
  url = ""
  if ipstring.index('/').nil? then
    subnet = IPAddr.new(ipstring)
    url = "ip:#{@enc_dblquote}#{subnet}#{@enc_dblquote}"
  else 
    subnet = IPAddr.new(locator)
    iprange = subnet.to_range()
    beginip = iprange.begin
    endip = iprange.end
    url = "ip#{@enc_colon}" + "[" + "#{beginip}" + " TO " + "#{endip}" + "]"
  end
  return url
end

def build_hostname_url(hostname)
  puts "building hostname url" if @debug
  return "hostname#{@enc_colon}#{@enc_dblquote}#{hostname}*#{@enc_dblquote}"
end



# Set a finite number of simultaneous worker threads that can run
thread_count = 15

# Create an array to keep track of threads
threads = Array.new(thread_count)

# Create a work queue for the producer to give work to the consumer
work_queue = SizedQueue.new(thread_count)

# Add a monitor so we can notify when a thread finishes and we can schedule a new one
threads.extend(MonitorMixin)

# Add a condition variable on the monitored array to tell the consumer to check the thread array
threads_available = threads.new_cond

# Add a variable to tell the consumer that we are done producing work
sysexit = false

## Set columns to use for tagging, if a @tag_column_file is provided

tag_columns = []
tag_list = [] 

## Set columns to use for tagging, if a @tag_column_file is provided

CSV.foreach(@tag_column_file, :headers => true, :encoding => "UTF-8"){|row|

  tag_columns << Array[row[0],row[1]]

}

  puts "tag_columns = #{tag_columns.to_s}" if @debug

start_time = Time.now
output_filename = "kenna-asset-tagger_log-#{start_time.strftime("%Y%m%dT%H%M")}.txt"

num_lines = CSV.read(@csv_file).length

  log_output = File.open(output_filename,'a+')
  log_output << "Processing CSV total lines #{num_lines}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
  log_output.close

producer_thread = Thread.new do
  puts "starting producer loop" if @debug
  

  ## Iterate through CSV
  CSV.foreach(@csv_file, :headers => true, :encoding => "UTF-8"){|row|

    current_line = $.

    asset_identifier = nil
    asset_id = nil

    log_output = File.open(output_filename,'a+')
    log_output << "Reading line #{$.}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
    log_output.close

    # Get 'asset' identifier and figure out if ip/hostname
    if @search_field == "ip_address" then
      if !row["#{@ip_address}"].nil? && is_ip?(row["#{@ip_address}"]) then
        api_query = build_ip_url(row["#{@ip_address}"])
      elsif !@hostname == '' && !row["#{@hostname}"].nil? then
          api_query = build_hostname_url(row["#{@hostname}"])
      else
        next
      end
    elsif @search_field == "hostname" then
      puts "#{row["#{@hostname}"]}#{row["#{@ip_address}"]}"
      if !row["#{@hostname}"].nil? then 
        api_query = build_hostname_url(row["#{@hostname}"])
      elsif !row["#{@ip_address}"].nil? && is_ip?(row["#{@ip_address}"]) then
        api_query = build_ip_url(row["#{@ip_address}"])
      else
        next
      end
    end
    api_query = api_query.gsub(' ', @enc_space)

    query_url = "#{@search_url}#{api_query}"

    log_output = File.open(output_filename,'a+')
    log_output << "Query URL...#{query_url}\n"
    log_output.close
  
  
    tag_list = [] 
    if tag_columns.count > 0 then
      tag_columns.each{|item|
        pull_column = []
        pull_string = ""
        pull_column = CSV.parse_line("#{item[0]}")
        pull_column.each{|col|
          pull_string << "#{row[col]} "
        } 
        pull_string = pull_string.strip
        pull_string = pull_string.gsub(/['<','>','\n','\t',':',';','(',')']/,'').chomp
        if !pull_string.nil? && !pull_string.empty? then
          if !item[1].nil? then
            tag_list << "#{item[1]}#{pull_string}"
          else
            tag_list << "#{pull_string}"
          end
        end
      }
    end

    tag_string = ""
    tag_list.each{|t| tag_string << "#{t},"}
    tag_string = tag_string[0...-1]
    puts "tag string = #{tag_string}" if @debug

    work_queue << Array[query_url,tag_string]

    threads.synchronize do
      threads_available.signal
    end

  }
  # Tell the consumer that we are finished downloading currencies
  sysexit = true
end

consumer_thread = Thread.new do
  loop do
    @retries = 0
    puts "at start of consumer loop" if @debug

    # Stop looping when the producer is finished producing work
    work_to_do = []
    work_to_do = work_queue.pop
    break if sysexit & work_queue.nil?
    found_index = nil

    # The MonitorMixin requires us to obtain a lock on the threads array in case
    # a different thread may try to make changes to it.
    threads.synchronize do
      # First, wait on an available spot in the threads array.  This fires every
      # time a signal is sent to the "threads_available" variable
      threads_available.wait_while do
        sleep(1.0/5.0)
        threads.select { |thread| thread.nil? || thread.status == false  ||
                                  thread["finished"].nil? == false}.length == 0
      end
      # Once an available spot is found, get the index of that spot so we may
      # use it for the new thread
      found_index = threads.rindex { |thread| thread.nil? || thread.status == false ||
                                              thread["finished"].nil? == false }
      puts "i just found index = #{found_index}" if @debug
    end
    # Get a new unit of work from the work queue

    query_url = work_to_do[0]
    tag_string = work_to_do[1]

    threads[found_index] = Thread.new(work_to_do) do
      puts "starting the thread loop" if @debug

    begin
      query_response = RestClient::Request.execute(
        method: :get,
        url: query_url,
        headers: @headers
      ) 
      rescue RestClient::TooManyRequests =>e
                retry
      rescue RestClient::UnprocessableEntity => e
        log_output = File.open(output_filename,'a+')
        log_output << "Unable to get Asset - #{e.backtrace.inspect}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
        log_output.close
        puts "Unable to get Asset: #{e.message}"
        Thread.exit
      rescue URI::InvalidURIError => e
        log_output = File.open(output_filename,'a+')
        log_output << "Unable to get Assets - InvalidURI: #{e.backtrace.inspect}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
        log_output.close
        puts "Unable to get assets: #{e.backtrace.inspect}"
        Thread.exit
      rescue RestClient::Exception => e
        @retries ||= 0
        if @retries < @max_retries
          @retries += 1
          sleep(15)
          retry
        else
          log_output = File.open(output_filename,'a+')
          log_output << "General RestClient error #{e.backtrace.inspect}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
          log_output.close
          puts "Unable to get assets: #{e.message}"
          Thread.exit
        end
    end 

    query_meta_json = JSON.parse(query_response)["meta"]
    total_found = query_meta_json.fetch("total_count")
    if total_found == 0 then
        log_output = File.open(output_filename,'a+')
        log_output << "Asset not found - #{query_url}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
        log_output.close
        puts "No matching assets found for #{query_url}" if @debug
        Thread.exit
    else

      query_response_json = JSON.parse(query_response)["assets"]

      query_response_json.each do |item|
        asset_id = item["id"]
        tag_update_json = {
          'asset' => {
            'tags' => "#{tag_string}"
          }
        }## Push tags to assets

        tag_api_url = "#{@asset_api_url}/#{asset_id}/tags"
      

        log_output = File.open(output_filename,'a+')
        log_output << "Post Asset URL...#{tag_api_url}\n"
        log_output << "Tags...#{tag_string}\n"
        log_output.close
        begin
          update_response = RestClient::Request.execute(
            method: :put,
            url: tag_api_url,
            headers: @headers,
            payload: tag_update_json
          )
            
            rescue RestClient::TooManyRequests =>e
                retry
            rescue RestClient::UnprocessableEntity => e
              log_output = File.open(output_filename,'a+')
              log_output << "Unable to update - UnprocessableEntity: #{e.backtrace.inspect}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
              log_output.close
              puts "Unable to update: #{e.message}"
              Thread.exit
            rescue RestClient::BadRequest => e
              log_output = File.open(output_filename,'a+')
              log_output << "Unable to update - BadRequest: #{e.backtrace.inspect}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
              log_output.close
              puts "Unable to update: #{e.message}"
              Thread.exit
            rescue RestClient::Exception => e
              @retries ||= 0
              if @retries < @max_retries
                @retries += 1
                sleep(15)
                retry
              else
                log_output = File.open(output_filename,'a+')
                log_output << "General RestClient error #{e.backtrace.inspect}... (time: #{Time.now.to_s}, start time: #{start_time.to_s})\n"
                log_output.close
                puts "Unable to update: #{e.message}"
                Thread.exit
              end
            end
        end
      end
    end
    Thread.current["finished"] = true

    # Tell the consumer to check the thread array
    threads.synchronize do
      threads_available.signal
    end
  end
end

# Join on both the producer and consumer threads so the main thread doesn't exit while
# they are doing work.
producer_thread.join
consumer_thread.join

# Join on the child processes to allow them to finish (if any are left)
threads.each do |thread|
    thread.join unless thread.nil?
end
puts "DONE!"

