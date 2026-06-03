import 'dart:convert';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const MyApp());
}

const String serverIp = "192.168.42.99";

// ─── Theme ───────────────────────────────────────────────────────────────────

class AppTheme {
  static const Color bg = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF13131A);
  static const Color surfaceHigh = Color(0xFF1C1C26);
  static const Color accent = Color(0xFF6C63FF);
  static const Color accentSoft = Color(0xFF2A2740);
  static const Color textPrimary = Color(0xFFEEEEF5);
  static const Color textSecondary = Color(0xFF8888AA);
  static const Color textMuted = Color(0xFF44445A);
  static const Color green = Color(0xFF34D399);
  static const Color greenSoft = Color(0xFF0D2E22);
  static const Color red = Color(0xFFFC6B6B);
  static const Color redSoft = Color(0xFF2E0D0D);
  static const Color border = Color(0xFF22223A);

  static ThemeData get theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          surface: surface,
        ),
        fontFamily: 'SF Pro Display',
        textTheme: const TextTheme(
          displayLarge: TextStyle(
              color: textPrimary, fontSize: 32, fontWeight: FontWeight.w700,
              letterSpacing: -1),
          titleLarge: TextStyle(
              color: textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(
              color: textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
          bodyLarge: TextStyle(color: textPrimary, fontSize: 16),
          bodyMedium: TextStyle(color: textSecondary, fontSize: 14),
          labelSmall: TextStyle(
              color: textMuted, fontSize: 11, letterSpacing: 1.2,
              fontWeight: FontWeight.w500),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: accent, width: 1.5),
          ),
          labelStyle: const TextStyle(color: textSecondary, fontSize: 14),
          hintStyle: const TextStyle(color: textMuted, fontSize: 14),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        ),
      );
}

// ─── App ─────────────────────────────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CallNet',
      theme: AppTheme.theme,
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─── Home Page ────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final TextEditingController myIdController = TextEditingController();
  final TextEditingController targetIdController = TextEditingController();

  WebSocketChannel? channel;
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  String? currentPeerId;

  bool connected = false;
  bool connecting = false;
  final List<RTCIceCandidate> pendingCandidates = [];

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  final Map<String, dynamic> configuration = {
    "iceServers": [
      {"urls": "stun:stun.l.google.com:19302"},
      {
        "urls": "turn:openrelay.metered.ca:80",
        "username": "openrelayproject",
        "credential": "openrelayproject",
      },
    ]
  };

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    localStream?.dispose();
    peerConnection?.close();
    channel?.sink.close();
    super.dispose();
  }

  Future<void> connect() async {
    final myId = myIdController.text.trim();
    if (myId.isEmpty) {
      _showSnack("Enter your ID first");
      return;
    }
    setState(() => connecting = true);

    try {
      channel = WebSocketChannel.connect(
        Uri.parse("ws://$serverIp:8000/ws/$myId"),
      );

      channel!.stream.listen((message) async {
        print("Received: $message");
        final parts = message.split("|");
        if (parts.length < 2) return;
        final sender = parts[0];
        final data = jsonDecode(parts[1]);

        switch (data["type"]) {
          case "offer":
            await _handleIncomingCall(sender, data);
            break;
          case "answer":
            await handleAnswer(data);
            break;
          case "candidate":
            await handleCandidate(data);
            break;
          case "user_not_found":
            _showSnack("User is offline");
            break;
        }
      });

      await initWebRTC();
      setState(() {
        connected = true;
        connecting = false;
      });
    } catch (e) {
      setState(() => connecting = false);
      _showSnack("Connection failed: $e");
    }
  }

  Future<void> initWebRTC() async {
  print("initWebRTC START");

  final status = await Permission.microphone.request();
  print("Mic permission: $status");

  if (!status.isGranted) {
    print("MIC DENIED");
    throw Exception("Microphone permission denied");
  }

  localStream = await navigator.mediaDevices.getUserMedia({
  "audio": {
    "echoCancellation": true,
    "noiseSuppression": true,
    "autoGainControl": true,
  },
  "video": false,
});

  print("Local stream created");

  peerConnection = await createPeerConnection(configuration);

  print("PeerConnection created");

  for (var track in localStream!.getTracks()) {
    print("Adding track: ${track.kind}");
    peerConnection!.addTrack(track, localStream!);
  }

  MediaStream? remoteStream;

peerConnection!.onTrack = (event) {
  if (event.streams.isNotEmpty) {
    remoteStream = event.streams[0];
  }
};

  peerConnection!.onIceCandidate = (candidate) {
  if (candidate.candidate == null) return;
  print("SENDING CANDIDATE");
  sendMessage(
    targetIdController.text.trim(),
    {
      "type": "candidate",
      "candidate": candidate.candidate,
      "sdpMid": candidate.sdpMid,
      "sdpMLineIndex": candidate.sdpMLineIndex,
    },
  );
};

  peerConnection!.onConnectionState = (state) {
  print("CONNECTION STATE: $state");

  if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
    _openCallScreen();
     }
  };
}

  void sendMessage(String target, Map<String, dynamic> data) {
    channel?.sink.add("$target|${jsonEncode(data)}");
  }

  Future<void> makeCall() async {
    final target = targetIdController.text.trim();
    currentPeerId = target;
    if (target.isEmpty) {
      _showSnack("Enter a target ID");
      return;
    }
    print("CREATING OFFER");
    final offer = await peerConnection!.createOffer();
    await peerConnection!.setLocalDescription(offer);
    sendMessage(target, {"type": "offer", "sdp": offer.sdp});

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallingScreen(
          callerId: myIdController.text.trim(),
          targetId: target,
          isOutgoing: true,
          onHangup: _hangup,
          peerConnection: peerConnection!,
        ),
      ),
    );
  }

  Future<void> _handleIncomingCall(
      String sender, Map<String, dynamic> data) async {
    currentPeerId = sender;
    targetIdController.text = sender;
    print("OFFER RECEIVED");
    await peerConnection!.setRemoteDescription(
      RTCSessionDescription(data["sdp"], "offer"),
    );

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          callerId: sender,
          onAccept: () async {
            Navigator.of(context).pop();
            final answer = await peerConnection!.createAnswer();
            await peerConnection!.setLocalDescription(answer);
            sendMessage(sender, {"type": "answer", "sdp": answer.sdp});
            Navigator.push(
                context,
                MaterialPageRoute(
                builder: (_) => CallingScreen(
                  callerId: myIdController.text,
                  targetId: sender,
                  isOutgoing: false,
                  onHangup: _hangup,
                  peerConnection: peerConnection!,
      ),
    ),
  );
          },
          onDecline: () {
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  void _openCallScreen() {
    if (!mounted) return;
    // If CallingScreen already open, it handles state internally
  }

  Future<void> handleAnswer(Map<String, dynamic> data) async {
  print("ANSWER RECEIVED");

  await peerConnection!.setRemoteDescription(
    RTCSessionDescription(data["sdp"], "answer"),
  );
  print("REMOTE DESCRIPTION SET");
}

  Future<void> handleCandidate(Map<String, dynamic> data) async {
    print("CANDIDATE RECEIVED");
    await peerConnection!.addCandidate(
      RTCIceCandidate(
        data["candidate"],
        data["sdpMid"],
        data["sdpMLineIndex"],
      ),
    );
     print("CANDIDATE ADDED");
  }

  Future<void> _hangup() async {
    await peerConnection?.close();
    peerConnection = null;
    await initWebRTC();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppTheme.surfaceHigh,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 48),
              _buildStatusCard(),
              const SizedBox(height: 32),
              _buildIdSection(),
              const SizedBox(height: 32),
              if (connected) _buildCallSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppTheme.accentSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.phone_rounded,
              color: AppTheme.accent, size: 20),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("CallNet",
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(letterSpacing: -0.5)),
            Text("Voice over WebRTC",
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        const Spacer(),
        if (connected)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.greenSoft,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.green.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, __) => Transform.scale(
                    scale: _pulseAnim.value,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppTheme.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Text("Online",
                    style: TextStyle(
                        color: AppTheme.green,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStatusCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            connected
                ? "Ready to call"
                : "Connect to get started",
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 18),
          ),
          const SizedBox(height: 6),
          Text(
            connected
                ? "Enter a target ID below and tap Call"
                : "Enter your ID and tap Connect to join the network",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          _WaveformVisualizer(active: connected),
        ],
      ),
    );
  }

  Widget _buildIdSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("YOUR ID",
            style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: myIdController,
                enabled: !connected,
                decoration: const InputDecoration(
                  hintText: "e.g. alice",
                  prefixIcon: Icon(Icons.person_outline_rounded,
                      color: AppTheme.textMuted, size: 20),
                ),
                style: const TextStyle(color: AppTheme.textPrimary),
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _ConnectButton(
              connected: connected,
              connecting: connecting,
              onTap: connected ? null : connect,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCallSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("CALL SOMEONE",
            style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 8),
        TextField(
          controller: targetIdController,
          decoration: const InputDecoration(
            hintText: "Enter their ID",
            prefixIcon: Icon(Icons.phone_outlined,
                color: AppTheme.textMuted, size: 20),
          ),
          style: const TextStyle(color: AppTheme.textPrimary),
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'\s')),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: makeCall,
            icon: const Icon(Icons.call_rounded, size: 20),
            label: const Text("Call",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Connect Button ───────────────────────────────────────────────────────────

class _ConnectButton extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final VoidCallback? onTap;

  const _ConnectButton(
      {required this.connected,
      required this.connecting,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              connected ? AppTheme.greenSoft : AppTheme.accentSoft,
          foregroundColor:
              connected ? AppTheme.green : AppTheme.accent,
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: connecting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.accent,
                ),
              )
            : Text(
                connected ? "Connected" : "Connect",
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

// ─── Waveform Visualizer ──────────────────────────────────────────────────────

class _WaveformVisualizer extends StatefulWidget {
  final bool active;
  const _WaveformVisualizer({required this.active});

  @override
  State<_WaveformVisualizer> createState() => _WaveformVisualizerState();
}

class _WaveformVisualizerState extends State<_WaveformVisualizer>
    with TickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(28, (i) {
              final phase = (i / 28) * 2 * pi;
              final wave = widget.active
                  ? (sin(_controller.value * 2 * pi + phase) * 0.5 + 0.5)
                  : 0.15;
              final height = 4.0 + wave * 24;
              return Container(
                width: 3,
                height: height,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: widget.active
                      ? AppTheme.accent.withOpacity(0.4 + wave * 0.6)
                      : AppTheme.textMuted.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

// ─── Incoming Call Screen ─────────────────────────────────────────────────────

class IncomingCallScreen extends StatefulWidget {
  final String callerId;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallScreen({
    super.key,
    required this.callerId,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  late AnimationController _ringController;
  late Animation<double> _ring1, _ring2, _ring3;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _ring1 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _ringController,
        curve: const Interval(0.0, 0.8, curve: Curves.easeOut),
      ),
    );
    _ring2 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _ringController,
        curve: const Interval(0.2, 1.0, curve: Curves.easeOut),
      ),
    );
    _ring3 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _ringController,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            _buildAvatar(),
            const SizedBox(height: 24),
            Text(
              widget.callerId,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5),
            ),
            const SizedBox(height: 8),
            const Text(
              "Incoming voice call",
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
            ),
            const Spacer(flex: 3),
            _buildActions(),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    return AnimatedBuilder(
      animation: _ringController,
      builder: (_, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            _buildRing(_ring1, 80),
            _buildRing(_ring2, 70),
            _buildRing(_ring3, 60),
            child!,
          ],
        );
      },
      child: _AvatarCircle(
          name: widget.callerId, size: 96, fontSize: 36),
    );
  }

  Widget _buildRing(Animation<double> anim, double maxRadius) {
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) {
        return Opacity(
          opacity: (1 - anim.value).clamp(0, 1),
          child: Container(
            width: 96 + maxRadius * anim.value,
            height: 96 + maxRadius * anim.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.accent.withOpacity(0.4 * (1 - anim.value)),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CallActionButton(
          icon: Icons.call_end_rounded,
          color: AppTheme.red,
          bgColor: AppTheme.redSoft,
          label: "Decline",
          onTap: widget.onDecline,
        ),
        const SizedBox(width: 48),
        _CallActionButton(
          icon: Icons.call_rounded,
          color: AppTheme.green,
          bgColor: AppTheme.greenSoft,
          label: "Accept",
          onTap: widget.onAccept,
        ),
      ],
    );
  }
}

// ─── Calling Screen ───────────────────────────────────────────────────────────

class CallingScreen extends StatefulWidget {
  final String callerId;
  final String targetId;
  final bool isOutgoing;
  final VoidCallback onHangup;
  final RTCPeerConnection peerConnection;

  const CallingScreen({
    super.key,
    required this.callerId,
    required this.targetId,
    required this.isOutgoing,
    required this.onHangup,
    required this.peerConnection,
  });

  @override
  State<CallingScreen> createState() => _CallingScreenState();
}

class _CallingScreenState extends State<CallingScreen>
    with TickerProviderStateMixin {
  bool _muted = false;
  bool _speakerOn = false;
  bool _connected = false;
  Duration _elapsed = Duration.zero;
  late AnimationController _connectController;

  @override
  void initState() {
    super.initState();
    _connectController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    widget.peerConnection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() => _connected = true);
        _connectController.forward();
        _startTimer();
      }
    };
  }

  void _startTimer() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || !_connected) return false;
      setState(() => _elapsed += const Duration(seconds: 1));
      return true;
    });
  }

  @override
  void dispose() {
    _connectController.dispose();
    super.dispose();
  }

  String get _formattedTime {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  Future<void> _toggleMute() async {
  setState(() => _muted = !_muted);
  for (var sender in await widget.peerConnection.getSenders()) {
    if (sender.track?.kind == "audio") {
      sender.track?.enabled = !_muted;
    }
  }
}

  void _toggleSpeaker() {
    setState(() => _speakerOn = !_speakerOn);
    // TODO: switch audio output
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            _buildStatusRow(),
            const Spacer(flex: 1),
            _AvatarCircle(
                name: widget.targetId, size: 100, fontSize: 38),
            const SizedBox(height: 24),
            Text(
              widget.targetId,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5),
            ),
            const SizedBox(height: 8),
            _buildCallState(),
            const Spacer(flex: 2),
            if (_connected) _buildControlRow(),
            const SizedBox(height: 32),
            _buildHangupButton(),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: const Icon(Icons.keyboard_arrow_down_rounded,
                  color: AppTheme.textSecondary, size: 22),
            ),
          ),
          const Spacer(),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.signal_cellular_alt_rounded,
                  size: 14,
                  color: _connected ? AppTheme.green : AppTheme.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  _connected ? "Connected" : "Connecting...",
                  style: TextStyle(
                      color: _connected
                          ? AppTheme.green
                          : AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallState() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: _connected
          ? Text(
              _formattedTime,
              key: const ValueKey('timer'),
              style: const TextStyle(
                  color: AppTheme.green,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2),
            )
          : const Text(
              "Calling...",
              key: ValueKey('calling'),
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 16),
            ),
    );
  }

  Widget _buildControlRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ToggleButton(
            icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: _muted ? "Unmute" : "Mute",
            active: _muted,
            onTap: _toggleMute,
          ),
          _ToggleButton(
            icon: _speakerOn
                ? Icons.volume_up_rounded
                : Icons.volume_down_rounded,
            label: "Speaker",
            active: _speakerOn,
            onTap: _toggleSpeaker,
          ),
        ],
      ),
    );
  }

  Widget _buildHangupButton() {
    return GestureDetector(
      onTap: () {
        widget.onHangup();
        Navigator.of(context).pop();
      },
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AppTheme.red,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppTheme.red.withOpacity(0.4),
              blurRadius: 24,
              spreadRadius: 0,
            ),
          ],
        ),
        child: const Icon(Icons.call_end_rounded,
            color: Colors.white, size: 30),
      ),
    );
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _AvatarCircle extends StatelessWidget {
  final String name;
  final double size;
  final double fontSize;

  const _AvatarCircle(
      {required this.name, required this.size, required this.fontSize});

  Color _colorFromName(String name) {
    final colors = [
      AppTheme.accent,
      const Color(0xFF34D399),
      const Color(0xFFF59E0B),
      const Color(0xFFEC4899),
      const Color(0xFF60A5FA),
    ];
    final index = name.isEmpty ? 0 : name.codeUnitAt(0) % colors.length;
    return colors[index];
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFromName(name);
    final initials = name.isEmpty
        ? '?'
        : name.length >= 2
            ? name.substring(0, 2).toUpperCase()
            : name[0].toUpperCase();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.15),
        border: Border.all(color: color.withOpacity(0.4), width: 2),
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: -1),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color bgColor;
  final String label;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.bgColor,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ToggleButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: active ? AppTheme.accentSoft : AppTheme.surface,
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? AppTheme.accent.withOpacity(0.5)
                    : AppTheme.border,
              ),
            ),
            child: Icon(
              icon,
              color: active ? AppTheme.accent : AppTheme.textSecondary,
              size: 26,
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  color: active
                      ? AppTheme.accent
                      : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}