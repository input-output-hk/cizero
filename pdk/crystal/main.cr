@[Link(wasm_import_module: "cizero")]
lib LibCizero
  fun toUpper(
    str : UInt8*
  )

  fun onCron(
    callback_name : UInt8*,
    cronspec : UInt8*
  ) : Int64

  fun onTimestamp(
    callback_name : UInt8*,
    timestamp_ms : Int64
  )

  fun exec(
    argv : UInt8**,
    argv_len : Int32,
    expand_arg0 : Bool,
    env : UInt8**,
    env_len : Int32,
    max_output_bytes : Int32,
    output : UInt8*,
    stdout_len : Int32*,
    stderr_len : Int32*,
    term_tag : Int8*,
    term_code : Int32*
  ) : Int8
end

# This function is never actually called, it works by magic!
fun ensure_constants_are_set
  pointerof(ARGF)
  pointerof(ARGV)
  pointerof(PROGRAM_NAME)
  pointerof(STDERR)
  pointerof(STDIN)
  pointerof(STDOUT)
  pointerof(Time::SECONDS_PER_DAY)
  pointerof(Time::DAYS_PER_400_YEARS)
  pointerof(Time::DAYS_PER_100_YEARS)
  pointerof(Time::DAYS_PER_4_YEARS)
  pointerof(Time::DAYS_MONTH_LEAP)
  pointerof(Time::DAYS_MONTH)
end

module Cizero
  def self.to_upper(str : String)
    LibCizero.toUpper(str)
    str
  end

  def self.on_cron(callback_name : String, cronspec : String)
    LibCizero.onCron(callback_name, cronspec)
  end

  def self.on_timestamp(callback_name : String, time : Time)
    LibCizero.onTimestamp(callback_name, time.to_unix_ms)
  end

  def self.exec(args : Array(String), env : Hash(String, String), max_output_bytes : Int32)
    output = Slice(UInt8).new(max_output_bytes)
    stdout_len = 0
    stderr_len = 0
    term_tag = 0.to_i8
    term_code = 0

    LibCizero.exec(
      argv: args.map(&.to_unsafe),
      argv_len: args.size,
      expand_arg0: false,
      env: env.map{|k,v| [k, v].map(&.to_unsafe) }.flatten,
      env_len: env.size * 2,
      max_output_bytes: max_output_bytes,
      output: output,
      stdout_len: pointerof(stdout_len),
      stderr_len: pointerof(stderr_len),
      term_tag: pointerof(term_tag),
      term_code: pointerof(term_code),
    )

    stdout = String.new(output[0...stdout_len])
    stderr = String.new(output[stdout_len...(stdout_len+stderr_len)])

    ExecResult.new(
      stdout: stdout,
      stderr: stderr,
      exit_code: term_code,
    )
  end

  struct ExecResult
    def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
    end

    def success?
      @exit_code == 0
    end
  end
end
