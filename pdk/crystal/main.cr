@[Link(wasm_import_module: "cizero")]
lib LibCizero
  fun timeout_on_cron(
    callback_name : UInt8*,
    user_data : UInt8*,
    user_data_size : Int32,
    cronspec : UInt8*
  ) : Int64

  fun timeout_on_timestamp(
    callback_name : UInt8*,
    user_data : UInt8*,
    user_data_size : Int32,
    timestamp_ms : Int64
  )

  fun nix_on_eval(
    func_name : UInt8*,
    user_data_ptr : UInt8*,
    user_data_len : Int32,
    expression : UInt8*,
    format : Int8
  )

  fun nix_on_build(
    func_name : UInt8*,
    user_data_ptr : UInt8*,
    user_data_len : Int32,
    installable : UInt8*
  )

  fun http_on_webhook(
    func_name : UInt8*,
    user_data_ptr : UInt8*,
    user_data_len : Int32
  )

  fun process_exec(
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

  fun on_webhook(
    callback_name : UInt8*,
    user_data : UInt8*,
    user_data_size : Int32
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

struct Pointer
  def as_s
    null? ? "null" : String.new(self)
  end

  def as_s(len)
    null? ? "null" : String.new(self, len)
  end
end

# fun main(argc : Int32, argv : UInt8**) : Int32
#   if argc > 0
#     Crystal.main(argc, argv)
#   else
#     fake_argv = Slice(Pointer(UInt8)).new(1, "foo".to_slice.to_unsafe)
#     Crystal.main(1, fake_argv.to_unsafe)
#   end
# end

MEMORY = [] of Pointer(UInt8)

fun cizero_mem_alloc(len : Int32, ptr_align : UInt8) : UInt8*
  Pointer(UInt8).malloc(len).tap { |ptr| MEMORY << ptr }
end

fun cizero_mem_resize(buf : UInt8**, buf_len : Int32, buf_align : UInt8, new_len : Int32) : Bool
  buf.realloc(new_len)
  true
end

fun cizero_mem_free(buf : UInt8**, buf_len : Int32, buf_align : UInt8)
  MEMORY.delete(buf)
end

module Cizero
  def self.timeout_on_timestamp(callback : String, time : Time, user_data : String) forall String
    LibCizero.timeout_on_timestamp(callback, user_data, user_data.size, time.to_unix_ms)
  end

  def self.timeout_on_timestamp(callback : String, time : Time, user_data : T) forall T
    LibCizero.timeout_on_timestamp(callback, pointerof(user_data).as(Pointer(UInt8)), sizeof(T), time.to_unix_ms)
  end

  def self.timeout_on_cron(callback : String, cronspec : String, user_data : String)
    LibCizero.timeout_on_cron(callback, user_data, user_data.size, cronspec)
  end

  def self.timeout_on_cron(callback : String, cronspec : String, user_data : T) forall T
    LibCizero.timeout_on_cron(callback, pointerof(user_data).as(Pointer(UInt8)), sizeof(T), cronspec)
  end

  enum NixEvalFormat
    Nix  = 0
    Json = 1
    Raw  = 2
  end

  def self.nix_on_eval(callback : String, expression : String, format : NixEvalFormat, user_data : T) forall T
    LibCizero.nix_on_eval(
      func_name: callback,
      user_data_ptr: pointerof(user_data).as(Pointer(UInt8)),
      user_data_len: sizeof(T),
      expression: expression,
      format: format,
    )
  end

  def self.nix_on_build(callback : String, installable : String, user_data : T) forall T
    LibCizero.nix_on_build(
      func_name: callback,
      user_data_ptr: pointerof(user_data).as(Pointer(UInt8)),
      user_data_len: sizeof(T),
      installable: installable,
    )
  end

  def self.http_on_webhook(callback : String, user_data : T) forall T
    # LibCizero.http_on_webhook(callback, pointerof(user_data).as(Pointer(UInt8)), sizeof(T))
    LibCizero.http_on_webhook(callback, user_data, 3)
  end

  # def self.on_webhook(callback : String, user_data : T) forall T
  #   LibCizero.on_webhook(callback, pointerof(user_data).as(Pointer(UInt8)), sizeof(T))
  # end

  # def self.on_timestamp(callback : String, time : Time, user_data : Int64)
  #   s = Slice(Int64).new(pointerof(user_data), 8)
  #   LibCizero.on_timestamp(callback, s.to_unsafe_bytes, s.size, time.to_unix_ms)
  # end

  # def self.on_timestamp(callback : String, time : Time, user_data : T? = nil) forall T
  #   case user_data
  #   in Struct
  #     LibCizero.on_timestamp(callback, user_data, user_data.size, time.to_unix_ms)
  #   in Int32
  #     s = Slice(Int32).new(pointerof(user_data), 3)
  #     LibCizero.on_timestamp(callback, s.to_unsafe_bytes, s.size, time.to_unix_ms)
  #   in Int64
  #     s = Slice(Int64).new(pointerof(user_data), 4)
  #     LibCizero.on_timestamp(callback, s.to_unsafe_bytes, s.size, time.to_unix_ms)
  #   end
  #   # if user_data.responds_to?(:to_unsafe)
  #   #   LibCizero.on_timestamp(callback, user_data, instance_sizeof(typeof(user_data)), time.to_unix_ms)
  #   # elsif user_data
  #   #   LibCizero.on_timestamp(callback, pointerof(user_data).as(Pointer(UInt8)), sizeof(typeof(user_data)), time.to_unix_ms)
  #   # else
  #   #   LibCizero.on_timestamp(callback, nil, 0, time.to_unix_ms)
  #   # end
  # end

  def self.process_exec(args : Array(String), env : Hash(String, String), max_output_bytes : Int32)
    output = Slice(UInt8).new(max_output_bytes)
    stdout_len = 0
    stderr_len = 0
    term_tag = 0.to_i8
    term_code = 0

    LibCizero.process_exec(
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
      term_code: term_code,
      term_tag: ExecResult::TermTag.new(term_tag),
    )
  end

  struct ExecResult
    enum TermTag
      Exited
      Signal
      Stopped
      Unknown
    end

    property stdout : String
    property stderr : String
    property term_code : Int32
    property term_tag : TermTag

    def initialize(@stdout, @stderr, @term_code, @term_tag)
    end

    def success?
      @term_code == 0
    end
  end
end
