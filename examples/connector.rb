# frozen_string_literal: true

require "ctx_checker"
require "net/connector"
require "digest"

# 本地 PTY 仅模拟设备字节；连接、驱动、解析与评估均使用真实实现。
class CheckerExampleTransport < Net::Connector::Transports::Pty
  INTERFACES = "GigabitEthernet1/0/1 is up, line protocol is up\n" \
    "  0 input errors, 0 CRC, 0 frame, 0 overrun, 0 ignored\n" \
    "  0 output errors, 0 collisions, 0 interface resets\n"
  BGP = "BGP router identifier 192.0.2.1, local AS number 65001\n" \
    "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n" \
    "192.0.2.2 4 65002 10 10 1 0 0 00:10:00 0\n"

  # 拒绝模式使用同一原生会话路径，不伪造 Driver 回执。
  def initialize(configuration, reject: false)
    super(configuration)
    @reject = reject
  end

  def argv
    program = <<~'RUBY'
      require "io/console"
      $stdin.raw!
      $stdout.sync = true
      print "device>"
      outputs = { "show interfaces" => ARGV.fetch(0), "show ip bgp summary" => ARGV.fetch(1) }
      seen = {}
      while (line = $stdin.gets("\n"))
        command = line.chomp
        abort "Unexpected or repeated query" if seen[command] || !outputs.key?(command)
        seen[command] = true
        print command, "\r\n", outputs.fetch(command).gsub("\n", "\r\n"), "device>"
      end
    RUBY
    output = @reject ? "% Invalid input detected at '^' marker.\n" : INTERFACES
    [ RbConfig.ruby, "--disable-gems", "-e", program, output, BGP ]
  end
end

target = { host: "192.0.2.10", platform: "cisco_ios" }
configuration = Net::Connector::Configuration.new(host: target[:host], username: "example", command_timeout: 2, login_timeout: 2)
collector = CtxChecker::Collector.new

[ false, true ].each do |reject|
  device = Net::Connector.build(:cisco_ios, configuration: configuration,
    transport: CheckerExampleTransport.new(configuration, reject: reject))
  begin
    device.connect
    snapshot = collector.collect_session(target: target, session: device, dimensions: %i[interfaces counters bgp])
    interfaces, counters, bgp = %i[interfaces counters bgp].map { |name| snapshot.observation(name) }
    report = CtxChecker::Evaluator.new.call(snapshot)
    if reject
      abort "Rejected query was treated as evidence" unless interfaces.status == :failed && counters.status == :failed
      abort "Closed session was retried" unless bgp.issues.any? { |issue| issue[:skipped] && issue[:code] == :device_error }
      abort "Failed collection was reported healthy" unless report.status == :unknown && !report.healthy?
      abort "Rejected native session remained connected" if device.connected?
    else
      abort "Collection lost parsed facts" unless [ interfaces, counters, bgp ].all?(&:complete?) &&
        interfaces.records.one? && interfaces.records.first[:name] == "GigabitEthernet1/0/1" &&
        counters.records.any? && bgp.records.one? && bgp.records.first[:state] == :established
      raw = "show interfaces\r\n#{CheckerExampleTransport::INTERFACES.gsub("\n", "\r\n")}device>"
      evidence = interfaces.evidence.first
      abort "Raw command evidence changed" unless evidence[:sha256] == Digest::SHA256.hexdigest(raw) && evidence[:bytes] == raw.bytesize
      abort "Shared query evidence diverged" unless interfaces.evidence == counters.evidence
      abort "Report lost command coverage" unless report.commands.size == 2 && report.healthy?
      abort "Borrowed session was closed" unless device.connected?
    end
  ensure
    device.close
  end
end

puts "Checker integration: PTY, shared queries, raw evidence, health, rejection and borrowed ownership passed"
