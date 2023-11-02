@[Link(wasm_import_module: "cizero")]
lib LibCizero
  fun toUpper(
    str : UInt8*
  )

  fun onCron(
    callback_name : UInt8*,
    user_data : UInt8*,
    user_data_size : Int32,
    cronspec : UInt8*
  ) : Int64

  fun onTimestamp(
    callback_name : UInt8*,
    user_data : UInt8*,
    user_data_size : Int32,
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

  fun onWebhook(
    callback_name : UInt8*,
    body : UInt8**,
    max_body_size : Int32
  )
end

# This function is never actually called, it works by magic!
# https://github.com/crystal-lang/crystal/issues/13888
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

MEMORY = [] of Pointer(UInt8)

fun cizero_mem_alloc(len : Int32, ptr_align : UInt8) : UInt8*
  Pointer(UInt8).malloc(len).tap { |ptr|
    MEMORY << ptr
  }
end

fun cizero_mem_resize(buf : UInt8**, buf_len : Int32, buf_align : UInt8, new_len : Int32) : Bool
  buf.realloc(new_len)
  true
end

fun cizero_mem_free(buf : UInt8**, buf_len : Int32, buf_align : UInt8)
  MEMORY.delete(buf)
end

module Cizero
  def self.on_webhook(callback_name : String, max_body_bytes : Int32) : String
    output = Slice(UInt8).new(max_body_bytes)
    LibCizero.onWebhook(callback_name, output, max_body_bytes)
    String.new(output)
  end

  def self.to_upper(str : String) : String
    LibCizero.toUpper(str)
    str
  end

  def self.on_cron(callback : String, cronspec : String, user_data : T? = nil) forall T
    if user_data
      LibCizero.onCron(callback, user_data.to_slice, user_data.size, cronspec)
    else
      LibCizero.onCron(callback, nil, 1, cronspec)
    end
  end

  def self.on_timestamp(callback : String, time : Time, user_data : T? = nil) forall T
    if user_data
      LibCizero.onTimestamp(callback, user_data.to_slice, user_data.size, time.to_unix_ms)
    else
      LibCizero.onTimestamp(callback, nil, 1, time.to_unix_ms)
    end
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
      env: env.map { |k, v| [k, v].map(&.to_unsafe) }.flatten,
      env_len: env.size * 2,
      max_output_bytes: max_output_bytes,
      output: output,
      stdout_len: pointerof(stdout_len),
      stderr_len: pointerof(stderr_len),
      term_tag: pointerof(term_tag),
      term_code: pointerof(term_code),
    )

    stdout = String.new(output[0...stdout_len])
    stderr = String.new(output[stdout_len...(stdout_len + stderr_len)])

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
