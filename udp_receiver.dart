import 'dart:convert';
import 'dart:io';

/// Handles binding to a local UDP port to listen for data broadcasted by the ESP32 node.
class UdpReceiver {
  final int port;
  final Function(double bpm, double spo2) onDataReceived;
  final Function(String error) onError;
  RawDatagramSocket? _socket;
  bool _isListening = false;

  UdpReceiver({
    this.port = 4210,
    required this.onDataReceived,
    required this.onError,
  });

  bool get isListening => _isListening;

  /// Starts listening for UDP packets on the specified port.
  Future<void> start() async {
    if (_isListening) return;

    try {
      // Bind to 0.0.0.0 (any local network interface) on the specified port
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      _socket?.multicastLoopback = true;
      _isListening = true;

      _socket?.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            Datagram? datagram = _socket?.receive();
            if (datagram != null) {
              final payload = utf8.decode(datagram.data).trim();
              _parseAndEmit(payload);
            }
          }
        },
        onError: (e) {
          onError("Socket error: $e");
          stop();
        },
        onDone: () {
          _isListening = false;
        },
      );
    } catch (e) {
      onError("Could not bind UDP socket on port $port: $e");
      _isListening = false;
    }
  }

  /// Parses the incoming payload ("BPM,SpO2") and triggers the callback.
  void _parseAndEmit(String payload) {
    try {
      final parts = payload.split(',');
      if (parts.length >= 2) {
        final bpm = double.parse(parts[0]);
        final spo2 = double.parse(parts[1]);
        onDataReceived(bpm, spo2);
      } else {
        onError("Invalid payload format (expected CSV): '$payload'");
      }
    } catch (e) {
      onError("Failed to parse UDP packet payload '$payload': $e");
    }
  }

  /// Closes the socket and stops listening.
  void stop() {
    _socket?.close();
    _socket = null;
    _isListening = false;
  }
}
