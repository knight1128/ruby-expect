#####
# = LICENSE
#
# Copyright 2012 Andrew Bates Licensed under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with the
# License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.
#
# the origin of this file is 'https://github.com/abates/ruby_expect', http://www.andrewbates.co/ruby-expect/
# 

require 'thread'
require 'pty'

#####
#
#
module RubyExpect
  #####
  # This is the main class used to interact with IO objects An Expect object can
  # be used to send and receive data on any read/write IO object.
  #
  class Expect
    # Any data that was in the accumulator buffer before match in the last expect call
    # if the last call to expect resulted in a timeout, then before is an empty string
    attr_reader :before

    # The exact string that matched in the last expect call
    attr_reader :match

    # The MatchData object from the last expect call or nil upon a timeout
    attr_reader :last_match

    # The accumulator buffer populated by read_loop.  Only access this if you really
    # know what you are doing!
    attr_reader :buffer

    #####
    # Create a new Expect object for the given IO object
    #
    # There are two ways to create a new Expect object.  The first is to supply
    # a single IO object with a read/write mode.  The second method is to supply
    # a read file handle as the first argument and a write file handle as the
    # second argument.
    #
    # +args+::
    #   at most 3 arguments, 1 or 2 IO objects (read/write or read + write and
    #   an optional options hash.  The only currently supported option is :debug
    #   (default false) which, if enabled, will send data received on the input
    #   filehandle to STDOUT
    #
    # +block+::
    #   An optional block called upon initialization.  See procedure
    #
    # == Examples
    #
    #   # expect with a read/write filehandle
    #   exp = Expect.new(rwfh)
    #
    #   # expect with separate read and write filehandles
    #   exp = Expect.new(rfh, wfh)
    #
    #   # turning on debugging
    #   exp = Expect.new(rfh, wfh, :debug => true)
    #
    def initialize *args, &block
      options = {}
      if (args.last.is_a?(Hash))
        options = args.pop
      end

      raise ArgumentError("First argument must be an IO object") unless (args[0].is_a?(IO))
      if (args.size == 1)
        @write_fh = args.shift
        @read_fh = @write_fh
      elsif (args.size == 2)
        raise ArgumentError("Second argument must be an IO object") unless (args[1].is_a?(IO))
        @write_fh = args.shift
        @read_fh = args.shift
      else
        raise ArgumentError.new("either specify a read/write IO object, or a read IO object and a write IO object")
      end

      raise "Input file handle is not readable!" unless (@read_fh.stat.readable?)
      raise "Output file handle is not writable!" unless (@write_fh.stat.writable?)

      @buffer_sem = Mutex.new
      @buffer_cv = ConditionVariable.new
      @child_pid = options[:child_pid]
      @debug = options[:debug] || false
      @buffer = ''
      @before = ''
      @match = ''
      @timeout = 0

      read_loop # start the read thread

      unless (block.nil?)
        procedure(&block)
      end
    end

    #####
    # Spawn a command and interact with it
    #
    # +command+::
    #   The command to execute
    #
    # +block+::
    #   Optional block to call and run a procedure in
    #
    def self.spawn command, options = {}, &block
      shell_in, shell_out, pid = PTY.spawn(command)
      options[:child_pid] = pid
      return RubyExpect::Expect.new(shell_out, shell_in, options, &block)
    end


    #####
    # Connect to a socket
    #
    # +command+::
    #   The socket or file to connect to
    #
    # +block+::
    #   Optional block to call and run a procedure in
    #
    def self.connect socket, options = {}, &block
      require 'socket'
      client = nil
      if (socket.is_a?(UNIXSocket))
       client = socket
      else
       client = UNIXSocket.new(socket)
      end
      return RubyExpect::Expect.new(client, options, &block)
    end

    #####
    # Perform a series of 'expects' using the DSL defined in Procedure
    #
    # +block+::
    #   The block will be called in the context of a new Procedure object
    #
    # == Example
    #
    #    exp = Expect.new(io)
    #    exp.procedure do
    #     each do
    #       expect /first expected line/ do
    #         send "some text to send"
    #       end
    #
    #       expect /second expected line/ do
    #         send "some more text to send"
    #       end
    #     end
    #    end
    #
    def procedure &block
      RubyExpect::Procedure.new(self, &block)
    end

    #####
    # Set the time to wait for an expected pattern
    #
    # +timeout+::
    #   number of seconds to wait before giving up.  A value of zero means wait
    #   forever
    #
    def timeout= timeout
      unless (timeout.is_a?(Integer))
        raise "Timeout must be an integer"
      end
      unless (timeout >= 0)
        raise "Timeout must be greater than or equal to zero"
      end

      @timeout = timeout
      @end_time = 0
    end

    ####
    # Get the current timeout value
    #
    def timeout
      @timeout
    end

    #####
    # Convenience method that will send a string followed by a newline to the
    # write handle of the IO object
    #
    # +command+::
    #   String to send down the pipe
    #
    def send command
      @write_fh.write("#{command}\n")
    end

    #####
    # Wait until either the timeout occurs or one of the given patterns is seen
    # in the input.  Upon a match, the property before is assigned all input in
    # the accumulator before the match, the matched string itself is assigned to
    # the match property and an optional block is called
    #
    # The method will return the index of the matched pattern or nil if no match
    # has occurred during the timeout period
    #
    # +patterns+::
    #   list of patterns to look for.  These can be either literal strings or
    #   Regexp objects
    #
    # +block+::
    #   An optional block to be called if one of the patterns matches
    #
    # == Example
    #
    #    exp = Expect.new(io)
    #    exp.expect('Password:') do
    #      send("12345")
    #    end
    #
    def expect *patterns, &block
      patterns = pattern_escape(*patterns)
      @end_time = 0
      if (@timeout != 0)
        @end_time = Time.now + @timeout
      end

      @before = ''
      matched_index = nil
      while (@end_time == 0 || Time.now < @end_time)
        return nil if (@read_fh.closed?)
        @last_match = nil
        @buffer_sem.synchronize do
          patterns.each_index do |i|
            if (match = patterns[i].match(@buffer))
              @last_match = match
              @before = @buffer.slice!(0...match.begin(0))
              @match = @buffer.slice!(0...match.to_s.length)
              matched_index = i
              break
            end
          end
          @buffer_cv.wait(@buffer_sem) if (@last_match.nil?)
        end
        unless (@last_match.nil?)
          unless (block.nil?)
            instance_eval(&block)
          end
          return matched_index
        end
      end
      return nil
    end

    def soft_close
      while (! @read_fh.closed?)
        @buffer_sem.synchronize do
          @buffer_cv.wait(@buffer_sem)
        end
      end
      @read_fh.close unless (@read_fh.closed?)
      @write_fh.close unless (@write_fh.closed?)
      if (@child_pid)
        Process.wait(@child_pid)
      end
    end

    private
      #####
      # This method will convert any strings in the argument list to regular
      # expressions that search for the literal string
      #
      # +patterns+::
      #   List of patterns to escape
      #
      def pattern_escape *patterns
        escaped_patterns = []
        patterns.each do |pattern|
          if (pattern.is_a?(String))
            pattern = Regexp.new(Regexp.escape(pattern))
          elsif (! pattern.is_a?(Regexp))
            raise "Don't know how to match on a #{pattern.class}"
          end
          escaped_patterns.push(pattern)
        end
        escaped_patterns
      end

      #####
      # The read loop is an internal method that constantly waits for input to
      # arrive on the IO object.  When input arrives it is appended to an
      # internal buffer for use by the expect method
      #
      def read_loop
        Thread.abort_on_exception = true
        Thread.new do
          while (true)
            begin
              ready = IO.select([@read_fh], nil, nil, 1)
              if (ready.nil? || ready.size == 0)
                @buffer_cv.signal()
              else
                if (@read_fh.eof?)
                  @read_fh.close
                  @buffer_cv.signal()
                  break
                else
                  input = @read_fh.readpartial(4096)
                  @buffer_sem.synchronize do
                    @buffer << input
                    @buffer_cv.signal()
                  end
                  if (@debug)
                    STDERR.print input
                    STDERR.flush
                  end
                end
              end
            rescue EOFError => e
            rescue Exception => e
              unless (e.to_s == 'stream closed')
                STDERR.puts "Exception in read_loop:"
                STDERR.puts "#{e}"
                STDERR.puts "\t#{e.backtrace.join("\n\t")}"
              end
              break
            end
          end
        end
      end
  end
end

#####
#
#
module RubyExpect
  #####
  # A pattern is a simple container to hold a string/regexp pattern and proc to
  # be called upon match.  This is an internal container used by the Procedure
  # class
  #
  class Pattern
    attr_reader :pattern, :block
    #####
    # +pattern+::
    #   String or Regexp objects to match on
    #
    # +block+::
    #   The block/proc to be called if a match occurs
    #
    def initialize pattern, &block
      @pattern = pattern
      @block = block
    end
  end

  #####
  # Super class for common methods for AnyMatch and EachMatch
  #
  class Match
    #####
    # +exp_object+::
    #   The expect object used for interaction
    #
    # +block+::
    #   The block will be called in the context of the initialized match object
    #
    def initialize exp_object, &block
      @exp = exp_object
      @patterns = []
      instance_eval(&block) unless block.nil?
    end

    #####
    # Add a pattern to be expected by the process
    #
    # +pattern+::
    #   String or Regexp to match on
    #
    # +block+::
    #   Block to be called upon a match
    #
    def expect pattern, &block
      @patterns.push(Pattern.new(pattern, &block))
    end
  end

  #####
  # Expect any one of the specified patterns and call the matching pattern's
  # block
  #
  class AnyMatch < Match
    #####
    # Procedure input data for the set of expected patterns
    #
    def run
      retval = @exp.expect(*@patterns.collect {|p| p.pattern})
      unless (retval.nil?)
        @exp.instance_eval(&@patterns[retval].block) unless (@patterns[retval].block.nil?)
      end
      return retval
    end
  end

  #####
  # Expect each of a set of patterns
  #
  class EachMatch < Match
    #####
    # Procedure input data for the set of expected patterns
    #
    def run
      @patterns.each_index do |i|
        retval = @exp.expect(@patterns[i].pattern, &@patterns[i].block)
        return nil if (retval.nil?)
      end
      return nil
    end
  end

  #####
  # A procedure is a set of patterns to match and blocks to be called upon
  # matching patterns.  This is useful for building blocks of expected sequences
  # of input data.  An example of this could be logging into a system using SSH
  #
  # == Example
  #
  #  retval = 0
  #  while (retval != 2)
  #    retval = any do
  #      expect /Are you sure you want to continue connecting \(yes\/no\)\?/ do
  #        send 'yes'
  #      end
  #
  #      expect /password:\s*$/ do
  #        send password
  #      end
  #
  #      expect /\$\s*$/ do
  #        send 'uptime'
  #      end
  #    end
  #  end
  #
  #  # Expect each of the following
  #  each do
  #    expect /load\s+average:\s+\d+\.\d+,\s+\d+\.\d+,\s+\d+\.\d+/ do # expect the output of uptime
  #      puts last_match.to_s
  #    end
  #
  #    expect /\$\s+$/ do # shell prompt
  #      send 'exit'
  #    end
  #  end
  #
  class Procedure
    #####
    # Create a new procedure to be executed by the expect object
    #
    # +exp_object+::
    #   The expect object that will execute this procedure
    #
    # +block+::
    #   The block to be called that defined the procedure
    #
    def initialize exp_object, &block
      raise "First argument must be a RubyExpect::Expect object" unless (exp_object.is_a?(RubyExpect::Expect))
      @exp = exp_object
      @steps = []
      instance_eval(&block) unless block.nil?
    end

    #####
    # Add an 'any' block to the Procedure.  The block will be evaluated using a
    # new AnyMatch instance
    #
    # +block+::
    #   The block the specifies the patterns to expect
    #
    def any &block
      RubyExpect::AnyMatch.new(@exp, &block).run
    end

    #####
    # Add an 'each' block to the Procedure.  The block will be evaluated using a
    # new EachMatch instance
    #
    # +block+::
    #   The block that specifies the patterns to expect
    #
    def each &block
      RubyExpect::EachMatch.new(@exp, &block).run
    end
  end
end
