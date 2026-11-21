# frozen_string_literal: true

require_relative 'test_helper'

class NetworkTest < Minitest::Test
  def test_transports_drain_and_reject_nil
    [:queue, :pipe].each do |type|
      channel = Rettle::Network.new(type: type)
      assert_raises(ArgumentError) { channel.write(nil) }
      channel.write(false)
      channel.write({a: 1})
      channel.close
      assert_equal false, channel.read
      assert_equal({a: 1}, channel.read)
      assert_nil channel.read
      assert_nil channel.read
      assert channel.instance_variable_get(:@channel)[0].closed? if type == :pipe
    end
  end

  def test_invalid_transport
    assert_raises(ArgumentError) { Rettle::Network.new(type: :invalid) }
  end

  def test_truncated_frame
    channel = Rettle::Network.new(type: :pipe)
    reader, writer = channel.instance_variable_get(:@channel)
    writer.write("10\n12")
    writer.close
    assert_raises(Rettle::Network::ProtocolError) { channel.read }
    assert reader.closed?
  ensure
    reader&.close unless reader&.closed?
  end

  def test_invalid_marshaled_regexp_closes_reader
    channel = Rettle::Network.new(type: :pipe)
    reader, writer = channel.instance_variable_get(:@channel)
    payload = "\x04\x08/\x08(?+\x00".b.unpack1('h*')
    writer.write("#{payload.bytesize}\n#{payload}")
    writer.close
    assert_raises(Rettle::Network::ProtocolError) { channel.read }
    assert reader.closed?
  ensure
    writer&.close unless writer&.closed?
    reader&.close unless reader&.closed?
  end

  def test_writes_after_close_raise_closed_channel_error
    [:queue, :pipe].each do |type|
      channel = Rettle::Network.new(type: type)
      channel.close
      assert_raises(Rettle::Network::ClosedChannelError) { channel.write(1) }
      channel.close_reader
    end
  end

  def test_broken_pipe
    channel = Rettle::Network.new(type: :pipe)
    reader, = channel.instance_variable_get(:@channel)
    reader.close
    assert_raises(Rettle::Network::ClosedChannelError) { channel.write('x') }
  ensure
    channel&.close
  end
end
