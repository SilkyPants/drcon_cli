import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

enum RconState {
  disconnected,
  connecting,
  authenticating,
  connected,
}

class RconClient {
  late Socket _socket;
  int _requestId = 0;

  final dataBuffer = <int>[];

  RconState _connectionState = RconState.disconnected;
  RconState get connectionState => _connectionState;
  bool get isAuthenticating =>
      _connectionState == RconState.connecting ||
      _connectionState == RconState.authenticating;

  Future<bool> connect(String host, int port, String password) async {
    _connectionState = RconState.connecting;

    _socket = await Socket.connect(host, port);

    _socket.listen(
      // handle data from the client
      _processIncomingData,

      // handle errors
      onError: (error) {
        print(error);
        close();
      },

      // handle the client closing the connection
      onDone: () {
        print('Client left');
        close();
      },
    );

    _connectionState = RconState.authenticating;
    _socket.add(_buildPacket(0, RconPacketType.login, password));
    await _socket.flush();

    await Future.microtask(() async {
      while (isAuthenticating) {
        await Future.delayed(Duration(milliseconds: 100));
      }
    });

    return connectionState == RconState.connected;
  }

  _processIncomingData(Uint8List data) {
    print('Data Recieved');
    dataBuffer.addAll(data);
    final responses = _readPackets();
    for (var response in responses) {
      print(response);

      if (isAuthenticating &&
          response.type == RconPacketType.authResponse &&
          response.id != -1) {
        _connectionState = RconState.connected;
      }
    }
  }

  Future<String> sendCommand(String command) async {
    final packet = _buildPacket(
      _getNextRequestId(),
      RconPacketType.command,
      command,
    );
    print('Sending packet: $packet');
    _socket.add(packet);
    await _socket.flush();

    // var response = await _readPacket();
    // if (!_isValidResponse(response, RconPacketType.command)) {
    //   throw Exception('Failed to execute command');
    // }

    return '';
    //response.payload;
  }

  Uint8List _buildPacket(
      int requestId, RconPacketType packetType, String payload) {
    var payloadLength = payload.length;
    var packetLength = 14 + payloadLength;
    var packet = Uint8List(packetLength);

    packet.setRange(0, 4, _intToBytes(packetLength - 4));
    packet.setRange(4, 8, _intToBytes(requestId));
    packet.setRange(8, 12, _intToBytes(packetType.rawValue));
    packet.setRange(12, packetLength - 2, payload.codeUnits);
    packet.setRange(packetLength - 2, packetLength, [0, 0]);

    return packet;
  }

  List<RconPacket> _readPackets() {
    final packets = <RconPacket>[];

    Uint8List.fromList(dataBuffer);

    // Peek the first 4 bytes (this is the packet length)
    var packetLength = _bytesToInt(dataBuffer.sublist(0, 4));
    // If this is smaller than our buffer then we have everything
    // for at least one packet
    while ((packetLength + 4) <= dataBuffer.length) {
      // Grab the data and parse
      final packetData =
          Uint8List.fromList(dataBuffer.sublist(0, packetLength + 4));
      final packet = _readPacket(packetData);
      packets.add(packet);
      // Remove the bytes from the buffer
      dataBuffer.removeRange(0, packetLength + 4);
    }

    return packets;
  }

  RconPacket _readPacket(Uint8List data) {
    var packetLength = _bytesToInt(data.sublist(0, 4));
    var packetId = _bytesToInt(data.sublist(4, 8));
    var packetType = _bytesToInt(data.sublist(8, 12));
    var payload =
        packetLength > 10 ? String.fromCharCodes(data.sublist(12)) : '';

    return RconPacket(
      packetId,
      RconPacketType.fromInt(packetType),
      payload,
      data,
    );
  }

  Uint8List _intToBytes(int value) {
    var byteData = ByteData(4);
    byteData.setUint32(0, value, Endian.little);
    return byteData.buffer.asUint8List();
  }

  int _bytesToInt(List<int> bytes) {
    var byteData = Uint8List.fromList(bytes);
    return ByteData.view(byteData.buffer).getInt32(0, Endian.little);
  }

  int _getNextRequestId() {
    _requestId = (_requestId + 1) % 2147483647;
    return _requestId;
  }

  void close() {
    _socket.close();
    _connectionState = RconState.disconnected;
  }
}

enum RconPacketType {
  responseValue(0),
  command(2),
  authResponse(2),
  login(3);

  const RconPacketType(this.rawValue);
  final int rawValue;

  factory RconPacketType.fromInt(int value) {
    return RconPacketType.values[value];
  }
}

class RconPacket {
  final int id;
  final RconPacketType type;
  final String payload;
  final Uint8List data;

  RconPacket(this.id, this.type, this.payload, this.data);

  @override
  String toString() {
    return '($id) $type Payload\n"$payload"\n\n$data';
  }
}
