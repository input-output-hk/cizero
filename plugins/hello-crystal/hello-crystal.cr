require "../../pdk/crystal/main"

fun pdk_test_timeout_on_timestamp
  now = Time.new(seconds: 1, nanoseconds: 0, location: Time::Location.fixed(0))
  ms = now + 2.seconds

  STDERR.puts now.to_unix_ms,
    ms.to_unix_ms

  Cizero.timeout_on_timestamp(
    callback: "pdk_test_timeout_on_timestamp_callback",
    user_data: now.to_unix_ms,
    time: ms,
  )
end

fun pdk_test_timeout_on_timestamp_callback(user_data : Int64*, user_data_len : Int32)
  raise "Expected Int64" unless user_data_len == sizeof(Int64)
  STDERR.puts user_data.value
end

fun pdk_test_timeout_on_cron
  spec = "* * * * *"
  STDERR.puts spec,
    spec

  result = Cizero.timeout_on_cron("pdk_test_timeout_on_cron_callback", spec, spec)
  STDERR.puts result
end

fun pdk_test_timeout_on_cron_callback(user_data : UInt8*, user_data_len : Int32) : Int32
  STDERR.puts String.new(user_data, user_data_len)
  0
end

fun pdk_test_nix_on_eval
  expression = "(builtins.getFlake github:NixOS/nixpkgs/057f9aecfb71c4437d2b27d3323df7f93c010b7e).legacyPackages.x86_64-linux.hello.meta.description"
  format = Cizero::NixEvalFormat::Raw
  STDERR.puts "void",
    expression,
    format.to_s.downcase

  Cizero.nix_on_eval(
    callback: "pdk_test_nix_on_eval_callback",
    expression: expression,
    user_data: nil,
    format: format,
  )
end

fun pdk_test_nix_on_eval_callback(
  user_data : UInt8*,
  user_data_len : Int32,
  result : UInt8*,
  err_msg : UInt8*,
  failed_ifd : UInt8*,
  failed_ifd_deps_ptr : UInt8**,
  failed_ifd_deps_len : Int32
)
  failed_ifd_deps = (0...failed_ifd_deps_len).map { |n| String.new(failed_ifd_deps_ptr[n]) }

  STDERR.puts user_data ? user_data.as_s(user_data_len) : "void",
    result.as_s,
    err_msg.as_s,
    failed_ifd.as_s,
    "{ #{failed_ifd_deps.join(", ")} }"
end

fun pdk_test_process_exec
  result = Cizero.process_exec(["sh", "-c", <<-SH], {"foo" => "bar"}, 50 * 1024)
  echo     stdout
  echo >&2 stderr \\$foo="$foo"
  SH

  STDERR.puts(<<-OUT)
  term tag: #{result.term_tag}
  term code: #{result.term_code}
  stdout: #{result.stdout}
  stderr: #{result.stderr}
  OUT
end

fun pdk_test_nix_on_build
  callback = "pdk_test_nix_on_build_callback"
  installable = "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv^*"
  STDERR.puts "void",
    "/nix/store/g2mxdrkwr1hck4y5479dww7m56d1x81v-hello-2.12.1.drv^*"
  Cizero.nix_on_build(callback, installable, nil)
end

fun pdk_test_nix_on_build_callback(
  user_data : UInt8*,
  user_data_len : Int32,
  outputs_ptr : UInt8**,
  outputs_len : Int32,
  failed_deps_ptr : UInt8**,
  failed_deps_len : Int32,
)
  outputs = (0...outputs_len).map { |n| String.new(outputs_ptr[n]) }
  failed_deps = (0...failed_deps_len).map { |n| String.new(failed_deps_ptr[n]) }

  STDERR.puts user_data ? user_data.as_s(user_data_len) : "void",
    "{ #{outputs.join(", ")} }",
    "{ #{failed_deps.join(", ")} }"
end

fun pdk_test_http_on_webhook
  callback = "pdk_test_http_on_webhook_callback"
  user_data = Slice(UInt8).new(3)
  user_data[0] = 0x19
  user_data[1] = 0x74
  user_data[2] = 0x01
  # user_data = uninitialized LibCizero::HttpOnWebhookUserData
  # user_data.a = 25
  # user_data.b = 372
  STDERR.puts ".{ #{user_data[0]}, 372 }"
  Cizero.http_on_webhook(callback, user_data)
end

fun pdk_test_http_on_webhook_callback(
  user_data : UInt8*,
  user_data_len : Int32,
  req_body_ptr : UInt8*,
  res_status : UInt32*,
  res_body_ptr : UInt64*
) : Int32
  a = user_data[0]
  b_bytes = Slice(UInt8).new(2)
  b_bytes[0] = user_data[1]
  b_bytes[1] = user_data[2]
  b = b_bytes.unsafe_slice_of(UInt16)[0]

  STDERR.puts ".{ #{a}, #{b} }",
    String.new(req_body_ptr)

  res_status.value = 200
  res_body_ptr.value = "response body".to_unsafe.address

  0
end

lib LibCizero
  struct HttpOnWebhookUserData
    a : UInt8
    b : UInt16
  end
end
