@[Link(wasm_import_module: "cizero")]
lib Cizero
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

def test_exec
  argv = ["sh", "-c", <<-SH]
  echo this goes to stdout
  echo this goes to stderr >&2 
  echo hey: $hey
  SH

  output = Slice(UInt8).new(200)
  stdout_len = 0
  stderr_len = 0
  term_tag = 0.to_i8
  term_code = 0

  env = {"hey" => "World"}

  Cizero.exec(
    argv: argv.map(&.to_unsafe),
    argv_len: argv.size,
    expand_arg0: false,
    env: env.map { |k, v| [k, v].map(&.to_unsafe) }.flatten,
    env_len: env.size * 2,
    max_output_bytes: output.size,
    output: output,
    stdout_len: pointerof(stdout_len),
    stderr_len: pointerof(stderr_len),
    term_tag: pointerof(term_tag),
    term_code: pointerof(term_code),
  )

  puts "STDOUT: #{String.new(output[0...stdout_len]).inspect}"
  puts "STDERR: #{String.new(output[stdout_len...(stdout_len+stderr_len)]).inspect}"
  puts "term_tag: #{term_tag}, term_code: #{term_code}"
end

def test_to_upper
  buf = "Hello World!"
  Cizero.toUpper(buf)
  puts "toUpper: #{buf}"
end

fun on_timestamp
  puts "onTimestamp"
  puts Time.local(Time::Location.fixed(0)).to_s("%F %T")
end

fun on_cron
  puts "onCron"
  puts Time.local(Time::Location.fixed(0)).to_s("%F %T")
end

test_to_upper
test_exec
Cizero.onTimestamp("on_timestamp", (Time.local + 1.milliseconds).to_unix_ms) 
Cizero.onCron("on_cron", "* * * * *") 