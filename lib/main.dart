import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'dart:async'; 
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart'; 
import 'package:url_launcher/url_launcher.dart'; 
import 'package:awesome_notifications/awesome_notifications.dart'; 
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// === IMPORTAÇÕES DO MOTOR WHATSAPP NATIVO existe===
import 'package:whatsapp_bot_flutter/whatsapp_bot_flutter.dart';
import 'package:whatsapp_bot_flutter_mobile/whatsapp_bot_flutter_mobile.dart';

// ==========================================
// SERVIÇO GLOBAL DO WHATSAPP E LOGS (Atualizado para reatividade)
// Gerencia o estado da conexão e armazena logs para exibição na UI.
// ==========================================
class WhatsappService {
  static WhatsappClient? client;
  static String status = 'Desconectado';
  static String pairingCode = '';
  static Uint8List? qrCodeImage; 
  static String numeroConectado = ''; 
  
  // Usamos um ValueNotifier para que a UI de logs atualize sem precisar de setState na aba inteira
  static ValueNotifier<List<String>> logsNotifier = ValueNotifier([]);

  static void addLog(String msg) {
    List<String> currentLogs = List.from(logsNotifier.value);
    currentLogs.add(msg);
    if (currentLogs.length > 150) currentLogs.removeAt(0);
    logsNotifier.value = currentLogs;
  }

  static void clearLogs() {
    logsNotifier.value = [];
  }

  static String getRawLogs() {
    return logsNotifier.value.join('\n'); 
  }
}

// ==========================================
// FUNÇÕES AUXILIARES (TEMPO E TELEFONE)
// ==========================================
String formatarTelefoneBr(String numero) {
  String limpo = numero.replaceAll(RegExp(r'[^0-9]'), '');
  if (limpo.isEmpty) return limpo;
  if (limpo.startsWith('55') && limpo.length >= 12) return limpo;
  return '55$limpo';
}

int parseMinutos(String horario) {
  try {
    List<String> partes = horario.split(':');
    return (int.parse(partes[0]) * 60) + int.parse(partes[1]);
  } catch (e) {
    return 0;
  }
}

String formatarMinutos(int totalMinutos) {
  int h = (totalMinutos ~/ 60) % 24;
  int m = totalMinutos % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

// ==========================================
// LÓGICA DO FILTRO (Cérebro Otimizado e Limpo)
// Determina quais passageiros devem receber mensagem com base na regra e na data/hora atual.
// ==========================================
List<Pessoa> obterDestinatarios(RegraMensagem regra, List<Viagem> viagens, {bool isManual = false}) {
  DateTime agora = DateTime.now();
  const diasDaSemana = ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'];
  
  String hojeStr = diasDaSemana[agora.weekday - 1]; 
  String amanhaStr = diasDaSemana[agora.weekday % 7]; 

  Map<String, Pessoa> pessoasParaEnviar = {}; 

  for (var viagem in viagens) {
    bool adicionarViagem = false;

    // Filtro de Dia: Verifica se a carona bate com a regra (Dia Anterior, Dia Atual ou Fixo)
    if (regra.tipoDia == 'Dia Anterior') {
      if (viagem.dia == amanhaStr) adicionarViagem = true;
    } else if (regra.tipoDia == 'Dia da Carona') {
      if (viagem.dia == hojeStr) adicionarViagem = true;
    } else if (regra.tipoDia == 'Fixo') {
      if (viagem.dia == regra.diaFixo) {
        if (isManual || hojeStr == regra.diaFixo) adicionarViagem = true;
      }
    }

    if (adicionarViagem && regra.alvoCarona != viagem.tipo) {
      adicionarViagem = false;
    }

    // Filtro de Horário Dinâmico: "Minutos Depois"
    // Calcula se o momento atual está dentro da janela de disparo (ex: 10 min após a carona)
    if (adicionarViagem && !isManual && regra.tipoHorario == 'Minutos Depois') {
      int addedMins = int.tryParse(regra.valorHorario) ?? 0;
      int expectedMins = parseMinutos(viagem.horario) + addedMins;
      int currentMins = (agora.hour * 60) + agora.minute;
      
      int diff = currentMins - expectedMins;
      if (diff < -12 * 60) diff += 24 * 60; 
      if (diff > 12 * 60) diff -= 24 * 60;
      
      if (diff < -5 || diff > 45) {
        adicionarViagem = false;
      }
    }

    if (adicionarViagem) {
      for (var p in viagem.passageiros) {
        pessoasParaEnviar[p.telefone] = p; 
      }
    }
  }

  return pessoasParaEnviar.values.toList();
}

// ==========================================
// FUNÇÃO GLOBAL DE DISPARO COM RASTREIO DE ERROS
// Executa o envio imediato (usado nos testes manuais da UI).
// ==========================================
Future<int> executarRegra(RegraMensagem regra, List<Viagem> viagens, {bool isManual = false}) async {
  List<Pessoa> destinatarios = obterDestinatarios(regra, viagens, isManual: isManual);

  if (WhatsappService.client == null) return -1; 
  if (destinatarios.isEmpty) return 0; 

  int enviosComSucesso = 0;
  for (var pessoa in destinatarios) {
    try {
      String numeroFinal = formatarTelefoneBr(pessoa.telefone); 
      await WhatsappService.client!.chat.sendTextMessage(
        phone: numeroFinal, 
        message: regra.texto,
      );
      enviosComSucesso++;
      debugPrint("Mensagem enviada para $numeroFinal com sucesso!");
    } catch (e) {
      debugPrint("Erro da API ao enviar para ${pessoa.telefone}: $e");
    }
  }

  if (enviosComSucesso == 0 && destinatarios.isNotEmpty) return -2; 
  return enviosComSucesso;
}

// ==========================================
// INICIALIZAÇÃO COM TRAVA DE ROTAÇÃO E PERMISSÕES
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _initForegroundTask();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  
  await AwesomeNotifications().initialize(
    null,
    [NotificationChannel(channelKey: 'caronas_bot', channelName: 'Caronas Background Bot', channelDescription: 'Avisos de disparo', importance: NotificationImportance.High)]
  );
  
  runApp(const GerenciadorCaronaApp());
}

// ==========================================
// CONFIGURAÇÃO DO SERVIÇO DE FOREGROUND (Estratégia Tanque de Guerra)
// ==========================================
void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'caronas_foreground_service',
      channelName: 'Caronas BOT Service',
      channelDescription: 'Serviço que mantém o motor do WhatsApp ativo.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        name: 'ic_launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      interval: 5000, // O loop principal será controlado manualmente, isso é apenas um heartbeat
      isOnceEvent: false,
      autoRunOnBoot: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

@pragma('vm:entry-point')
void startCallback() {
  // A função de callback que será executada no Isolate de background.
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler implements TaskHandler {
  // TODO: Mover a lógica do antigo 'motorDeDisparoBackground' para cá.
  // A nova lógica será um loop contínuo (Timer.periodic) que verifica as regras
  // e dispara as mensagens, em vez de ser acionada por um alarme.

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    // Lógica a ser executada quando o serviço é iniciado.
    // No próximo passo, vamos implementar a conexão persistente aqui.
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    // Usado para comunicação da UI -> Background, se necessário.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    // Lógica de limpeza, como desconectar o cliente do WhatsApp.
    await FlutterForegroundTask.clearAllData();
  }

  @override
  void onButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}
}

// ==========================================
// ESTRUTURAS DE DADOS E APP TEMA
// ==========================================
class Pessoa {
  String nome; String telefone;
  Pessoa({required this.nome, required this.telefone});
  Map<String, dynamic> toJson() => {'nome': nome, 'telefone': telefone};
  factory Pessoa.fromJson(Map<String, dynamic> json) => Pessoa(nome: json['nome'], telefone: json['telefone']);
}

class Viagem {
  String id; String dia; String tipo; String horario; List<Pessoa> passageiros;
  final int limiteVagas = 4;
  Viagem({required this.id, required this.dia, required this.tipo, required this.horario, List<Pessoa>? passageiros}) : passageiros = passageiros ?? [];
  Map<String, dynamic> toJson() => {'id': id, 'dia': dia, 'tipo': tipo, 'horario': horario, 'passageiros': passageiros.map((p) => p.toJson()).toList()};
  factory Viagem.fromJson(Map<String, dynamic> json) => Viagem(id: json['id'], dia: json['dia'], tipo: json['tipo'], horario: json['horario'], passageiros: (json['passageiros'] as List).map((p) => Pessoa.fromJson(p)).toList());
}

class RegraMensagem {
  String texto; String tipoDia; String? diaFixo; String? alvoCarona; String tipoHorario; String valorHorario; bool ativo; 
  RegraMensagem({required this.texto, required this.tipoDia, this.diaFixo, this.alvoCarona, required this.tipoHorario, required this.valorHorario, this.ativo = true});
  Map<String, dynamic> toJson() => {'texto': texto, 'tipoDia': tipoDia, 'diaFixo': diaFixo, 'alvoCarona': alvoCarona, 'tipoHorario': tipoHorario, 'valorHorario': valorHorario, 'ativo': ativo};
  factory RegraMensagem.fromJson(Map<String, dynamic> json) => RegraMensagem(texto: json['texto'], tipoDia: json['tipoDia'], diaFixo: json['diaFixo'], alvoCarona: json['alvoCarona'], tipoHorario: json['tipoHorario'], valorHorario: json['valorHorario'], ativo: json['ativo'] ?? true);
}

class GerenciadorCaronaApp extends StatelessWidget {
  const GerenciadorCaronaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // O WithForegroundTask é necessário para que o app possa se comunicar com o serviço.
    return const WithForegroundTask(
      child: _AppCore(),
    );
  }
}

class _AppCore extends StatefulWidget {
  const _AppCore();
  @override
  State<_AppCore> createState() => __AppCoreState();
}
class __AppCoreState extends State<_AppCore> {
  bool isOledDark = false;
  Color corPrincipal = Colors.blue; 
  void mudarTema(bool dark, Color cor) { setState(() { isOledDark = dark; corPrincipal = cor; }); }

  @override
  Widget build(BuildContext context) {
    bool isTerminalMode = corPrincipal.value == Colors.greenAccent.value;
    bool aplicarModoEscuro = isOledDark || isTerminalMode;

    return MaterialApp(
      title: 'Caronas', debugShowCheckedModeBanner: false,
      themeMode: aplicarModoEscuro ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        colorSchemeSeed: corPrincipal, useMaterial3: true, brightness: Brightness.light,
        cardTheme: isTerminalMode ? const CardThemeData(color: Colors.transparent, elevation: 0) : null,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: corPrincipal, useMaterial3: true, brightness: Brightness.dark, 
        scaffoldBackgroundColor: aplicarModoEscuro ? Colors.black : null, 
        cardColor: (isOledDark && !isTerminalMode) ? const Color(0xFF121212) : null,
        cardTheme: isTerminalMode ? const CardThemeData(color: Colors.transparent, elevation: 0) : const CardThemeData(),
        dividerTheme: isTerminalMode ? DividerThemeData(color: Colors.greenAccent.withOpacity(0.3)) : null,
        listTileTheme: isTerminalMode ? const ListTileThemeData(iconColor: Colors.greenAccent) : null,
      ),
      home: TelaNavegacao(onThemeChanged: mudarTema, isDark: aplicarModoEscuro, currentColor: corPrincipal),
    );
  }
}

class TelaNavegacao extends StatefulWidget {
  final Function(bool, Color) onThemeChanged; final bool isDark; final Color currentColor;
  const TelaNavegacao({super.key, required this.onThemeChanged, required this.isDark, required this.currentColor});
  @override
  State<TelaNavegacao> createState() => _TelaNavegacaoState();
}

class _TelaNavegacaoState extends State<TelaNavegacao> {
  int _indiceAtual = 0;
  List<Pessoa> bancoContatos = []; 
  List<RegraMensagem> bancoRegras = []; 
  List<Viagem> viagens = []; 

  @override
  void initState() { super.initState(); _carregarDados(); }

  Future<void> _carregarDados() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (prefs.containsKey('contatos')) bancoContatos = List<Pessoa>.from(jsonDecode(prefs.getString('contatos')!).map((m) => Pessoa.fromJson(m)));
      if (prefs.containsKey('regras')) {
        bancoRegras = List<RegraMensagem>.from(jsonDecode(prefs.getString('regras')!).map((m) => RegraMensagem.fromJson(m)));
        for (var r in bancoRegras) { if (r.alvoCarona == 'Ambos' || r.alvoCarona == null) r.alvoCarona = 'Ida'; }
      }
      if (prefs.containsKey('viagens')) viagens = List<Viagem>.from(jsonDecode(prefs.getString('viagens')!).map((m) => Viagem.fromJson(m)));
      
      if (prefs.containsKey('whatsapp_numero')) {
        WhatsappService.numeroConectado = prefs.getString('whatsapp_numero')!;
        if (WhatsappService.numeroConectado.isNotEmpty && WhatsappService.status == "Desconectado") {
          // Apenas mostra visualmente que tem sessão salva, NÃO liga o motor sozinho.
          WhatsappService.status = "SESSÃO SALVA. RECONECTE SE NECESSÁRIO.";
        }
      }
      _ordenarCaronas();
    });
    // A chamada para atualizarAlarmesNoSistema foi removida.
  }

  Future<void> _salvarDados() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('contatos', jsonEncode(bancoContatos.map((e) => e.toJson()).toList()));
    prefs.setString('regras', jsonEncode(bancoRegras.map((e) => e.toJson()).toList()));
    prefs.setString('viagens', jsonEncode(viagens.map((e) => e.toJson()).toList()));
    // A chamada para atualizarAlarmesNoSistema foi removida.
  }

  void _ordenarCaronas() {
    const diasPeso = {'Segunda': 1, 'Terça': 2, 'Quarta': 3, 'Quinta': 4, 'Sexta': 5, 'Sábado': 6, 'Domingo': 7};
    viagens.sort((a, b) {
      int pesoA = diasPeso[a.dia] ?? 0; int pesoB = diasPeso[b.dia] ?? 0;
      if (pesoA != pesoB) return pesoA.compareTo(pesoB);
      int minutosA = parseMinutos(a.horario); int minutosB = parseMinutos(b.horario);
      if (minutosA != minutosB) return minutosA.compareTo(minutosB);
      return a.tipo == 'Ida' ? -1 : 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _indiceAtual,
          children: [
            DashboardTab(viagens: viagens, pessoasCadastradas: bancoContatos, onUpdate: () { setState(() => _ordenarCaronas()); _salvarDados(); }),
            ContatosTab(pessoas: bancoContatos, onUpdate: () { setState((){}); _salvarDados(); }),
            ConfigTab(regras: bancoRegras, viagens: viagens, onUpdate: () { setState((){}); _salvarDados(); }, isDark: widget.isDark, currentColor: widget.currentColor, onThemeChanged: widget.onThemeChanged),
            const WhatsAppConnectionTab(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _indiceAtual,
        onDestinationSelected: (int index) => setState(() => _indiceAtual = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Caronas'),
          NavigationDestination(icon: Icon(Icons.contacts_outlined), selectedIcon: Icon(Icons.contacts), label: 'Contatos'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ajustes'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'WhatsApp'),
        ],
      ),
    );
  }
}

// ==========================================
// ABA: WHATSAPP CONNECTION (ESTÁVEL COM MORTE SÚBITA)
// Tela de controle da conexão, QR Code e Logs.
// ==========================================
class WhatsAppConnectionTab extends StatefulWidget {
  const WhatsAppConnectionTab({super.key});
  @override
  State<WhatsAppConnectionTab> createState() => _WhatsAppConnectionTabState();
}

class _WhatsAppConnectionTabState extends State<WhatsAppConnectionTab> {
  final _phoneController = TextEditingController();
  bool _isLoading = false;
  bool _isCancelling = false; 

  Future<void> _checarBateriaEConectar() async {
    // Solicita permissões necessárias para o serviço de foreground
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    final NotificationPermission notificationPermission = await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // A lógica de iniciar o serviço será adicionada aqui nos próximos passos,
    // por enquanto, apenas mantemos a conexão da UI.
    // Ex: FlutterForegroundTask.startService(notificationTitle: 'Caronas BOT Ativo', notificationText: 'Monitorando...', callback: startCallback);


    FocusScope.of(context).unfocus();
    var statusBateria = await Permission.ignoreBatteryOptimizations.status;
    if (!statusBateria.isGranted) await Permission.ignoreBatteryOptimizations.request();
    _iniciarProcessoDeConexao();
  }

  // BOTÃO DE RELOAD (O Seu "Estado 3" Manual)
  // Força a reinicialização do motor limpando a instância da memória.
  Future<void> _recarregarMotor() async {
    setState(() { 
      _isLoading = true; 
      _isCancelling = false;
      WhatsappService.status = "RECARREGANDO MOTOR...";
    });
    WhatsappService.addLog("🔄 Aplicando Morte Súbita no motor atual para Sincronização limpa...");

    // A MORTE SÚBITA: Ignora o processo amigável de desconexão e mata a instância direto.
    // Isso evita o erro Invariant Violation e Multiple Roots
    WhatsappService.client = null;
    await Future.delayed(const Duration(seconds: 1));

    if (mounted && !_isCancelling) _iniciarProcessoDeConexao();
  }

  // BOTÃO DE PÂNICO (Cancela TUDO e limpa os Logs)
  // Interrompe qualquer tentativa de conexão em andamento.
  void _forcarCancelamento() {
    setState(() {
      _isCancelling = true;
      _isLoading = false;
      WhatsappService.status = "AÇÃO CANCELADA";
      WhatsappService.addLog("⚠️ Cancelamento forçado pelo usuário.");
      WhatsappService.clearLogs(); // Limpa a caixa preta
    });
    // Morte súbita no botão X
    WhatsappService.client = null;
  }

  Future<void> _iniciarProcessoDeConexao() async {
    if (_phoneController.text.isEmpty && WhatsappService.numeroConectado.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Digite o seu telefone!")));
      return;
    }
    
    String numBase = _phoneController.text.isNotEmpty ? _phoneController.text : WhatsappService.numeroConectado;
    String numeroFormatado = formatarTelefoneBr(numBase);

    setState(() { 
      _isLoading = true; 
      _isCancelling = false;
      WhatsappService.numeroConectado = numeroFormatado; 
      WhatsappService.clearLogs(); // Limpa os logs no boot
      WhatsappService.status = "INICIANDO MOTOR..."; 
      WhatsappService.pairingCode = "";
    });

    // Morte súbita preventiva antes de iniciar
    WhatsappService.client = null;

    try {
      // TIMEOUT DE 45 SEGUNDOS: Evita travamento infinito
      WhatsappService.client = await WhatsappBotFlutterMobile.connect(
        linkWithPhoneNumber: numeroFormatado,
        onPhoneLinkCode: (String code) async {
          if (!mounted || _isCancelling) return; 
          setState(() {
            WhatsappService.status = "PAREADO, VÁ PARA O WHATSAPP"; 
            WhatsappService.pairingCode = code; 
          });
          await Clipboard.setData(ClipboardData(text: code));
        },
        onConnectionEvent: (ConnectionEvent event) {
          if (!mounted || _isCancelling) return;
          setState(() {
            if (event.name == 'connecting') {
              if (WhatsappService.pairingCode.isEmpty) WhatsappService.status = "CONECTANDO...";
            } else if (event.name == 'connected') {
              WhatsappService.status = "CONECTADO"; 
              WhatsappService.numeroConectado = numeroFormatado;
              SharedPreferences.getInstance().then((prefs) => prefs.setString('whatsapp_numero', numeroFormatado));
            } else if (event.name == 'waitingForLogin' || event.name == 'waitingForPhoneLink') {
              // Ignora avisos inúteis do pacote
            } else {
              if (WhatsappService.pairingCode.isEmpty) WhatsappService.status = event.name.toUpperCase();
            }
          });
        },
      ).timeout(const Duration(seconds: 45), onTimeout: () {
        throw Exception("Timeout de Inicialização. O WhatsApp engasgou.");
      });

    } catch (e) {
      if (mounted && !_isCancelling) {
        setState(() { 
          WhatsappService.status = "ERRO, RECONECTE"; 
          WhatsappService.addLog("ERRO DA MÁQUINA: $e");
        });
      }
    } finally {
      if (mounted && !_isCancelling) {
        setState(() { _isLoading = false; });
      }
    }
  }

  Future<void> _desconectarWhatsApp() async {
    setState(() { _isLoading = true; });
    // Morte súbita para desconexão total
    WhatsappService.client = null;
    final prefs = await SharedPreferences.getInstance();
    prefs.remove('whatsapp_numero');

    if (mounted) {
      setState(() {
        _isLoading = false; 
        WhatsappService.status = 'DESCONECTADO'; 
        WhatsappService.pairingCode = ''; 
        WhatsappService.numeroConectado = '';
        _phoneController.clear();
        WhatsappService.clearLogs(); 
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Desconectado com sucesso e memória apagada.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    Color corAcento = Theme.of(context).colorScheme.primary;
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    
    bool emSessao = WhatsappService.status == "CONECTADO" || WhatsappService.status == "AUTHENTICATED";

    Color corDoStatus;
    if (emSessao) corDoStatus = Colors.green;
    else if (WhatsappService.status.contains("ERRO") || WhatsappService.status.contains("FALHA") || WhatsappService.status.contains("CANCELADA")) corDoStatus = Colors.red;
    else if (WhatsappService.status.contains("PAREADO") || WhatsappService.status.contains("SESSÃO SALVA")) corDoStatus = Colors.blue;
    else corDoStatus = isDark ? Colors.white : Colors.black; 

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Conexão com Whatsapp', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          
          Expanded(
            child: ListView(
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, 
                      children: [
                        const Text('STATUS:', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(
                          WhatsappService.status.toUpperCase(), 
                          style: TextStyle(color: corDoStatus, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),

                if (WhatsappService.pairingCode.isNotEmpty || !emSessao) ...[
                  GestureDetector(
                    onTap: () {
                      if (WhatsappService.pairingCode.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: WhatsappService.pairingCode));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Código copiado!'), backgroundColor: corAcento));
                      }
                    },
                    child: Container(
                      width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(color: corAcento.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: corAcento.withOpacity(0.5), width: 2)),
                      child: Column(
                        children: [
                          const Text('CÓDIGO DE LOGIN', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
                          const SizedBox(height: 8),
                          Text(
                            WhatsappService.pairingCode.isEmpty ? "---- ----" : WhatsappService.pairingCode, 
                            style: TextStyle(color: corAcento, fontSize: 40, letterSpacing: 8, fontWeight: FontWeight.bold), 
                            textAlign: TextAlign.center
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                
                const SizedBox(height: 16),
                
                // CAIXA DE LOGS REATIVA (ValueListenableBuilder)
                ValueListenableBuilder<List<String>>(
                  valueListenable: WhatsappService.logsNotifier,
                  builder: (context, logs, child) {
                    return Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: SizedBox(
                          height: 288, 
                          child: logs.isEmpty 
                              ? const Center(child: Text("Aguardando execução...", style: TextStyle(color: Colors.grey)))
                              : ListView.builder(
                                  reverse: true, // Gravidade invertida (Novos no fundo)
                                  itemCount: logs.length,
                                  itemBuilder: (ctx, i) {
                                    String log = logs.reversed.toList()[i];
                                    bool isError = log.contains("ERRO") || log.contains("FALHA") || log.contains("Timeout") || log.contains("Cancelamento");
                                    bool isHighlight = log.contains("CONECTADO") || log.contains("Código gerado!");
                                    
                                    Color textColor = isError ? Colors.red : (isHighlight ? corAcento : (isDark ? Colors.white70 : Colors.black87));
                                    
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 6.0),
                                      child: Text(
                                        log, 
                                        style: TextStyle(color: textColor, fontSize: 12, fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal)
                                      ),
                                    );
                                  }
                                ),
                        ),
                      ),
                    );
                  }
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 12),
          // SEÇÃO DE BOTÕES INFERIORES
          if (!emSessao) ...[
            TextField(
              controller: _phoneController, keyboardType: TextInputType.phone, enabled: !_isLoading, textInputAction: TextInputAction.done, 
              onSubmitted: (_) { if (!_isLoading) _checarBateriaEConectar(); },
              decoration: InputDecoration(labelText: WhatsappService.numeroConectado.isNotEmpty ? 'Reconectar: +${WhatsappService.numeroConectado}' : 'Seu WhatsApp (Ex: 12999999999)', border: const OutlineInputBorder(), prefixIcon: Icon(Icons.phone, color: !_isLoading ? corAcento : Colors.grey), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: corAcento, width: 2))),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50, 
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _checarBateriaEConectar, 
                      style: ElevatedButton.styleFrom(backgroundColor: corAcento, foregroundColor: Colors.white), 
                      child: _isLoading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : Text(WhatsappService.numeroConectado.isNotEmpty ? 'Reconectar Motor' : 'Gerar Código', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))
                    )
                  ),
                ),
                if (_isLoading) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 50, width: 50,
                    child: ElevatedButton(
                      onPressed: _forcarCancelamento,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      child: const Icon(Icons.close),
                    ),
                  )
                ]
              ],
            )
          ] else ...[
            Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey.withOpacity(0.5)), borderRadius: BorderRadius.circular(5)),
              child: Row(children: [Icon(Icons.phone, color: corAcento), const SizedBox(width: 12), Text('+${WhatsappService.numeroConectado}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))]),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50, 
                    child: ElevatedButton.icon(
                      onPressed: _desconectarWhatsApp, 
                      icon: const Icon(Icons.logout), 
                      label: const Text('DESCONECTAR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), 
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white)
                    )
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 50,
                  width: 60,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _recarregarMotor,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: corAcento, 
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                    ),
                    child: _isLoading 
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                        : const Icon(Icons.autorenew),
                  ),
                )
              ],
            ),
          ],
          const SizedBox(height: 10), 
        ],
      ),
    );
  }
}

// ==========================================
// ABA 1: DASHBOARD
// ==========================================
class DashboardTab extends StatefulWidget {
  final List<Viagem> viagens; final List<Pessoa> pessoasCadastradas; final VoidCallback onUpdate;
  const DashboardTab({super.key, required this.viagens, required this.pessoasCadastradas, required this.onUpdate});
  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  final List<String> horariosFixos = ['8:00', '10:00', '12:00', '13:30', '15:30', '17:30', '19:00', '21:00', '23:00'];

  void _abrirForm(Viagem? v) {
    String dia = v?.dia ?? 'Segunda'; String hIda = v?.horario ?? '8:00'; String hVolta = '17:30';
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (ctx) => StatefulBuilder(builder: (ctx, setM) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(v == null ? 'Nova Carona' : 'Editar Carona', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 16),
      DropdownButtonFormField<String>(value: dia, items: ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'].map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(), onChanged: (val) => setM(() => dia = val!), decoration: const InputDecoration(labelText: 'Dia', border: OutlineInputBorder())), const SizedBox(height: 16),
      if (v == null) Row(children: [
        Expanded(child: DropdownButtonFormField<String>(value: hIda, items: horariosFixos.map((h) => DropdownMenuItem(value: h, child: Text(h))).toList(), onChanged: (val) => setM(() => hIda = val!), decoration: const InputDecoration(labelText: 'Ida', border: OutlineInputBorder()))), const SizedBox(width: 10),
        Expanded(child: DropdownButtonFormField<String>(value: hVolta, items: horariosFixos.map((h) => DropdownMenuItem(value: h, child: Text(h))).toList(), onChanged: (val) => setM(() => hVolta = val!), decoration: const InputDecoration(labelText: 'Volta', border: OutlineInputBorder()))),
      ]) else DropdownButtonFormField<String>(value: hIda, items: horariosFixos.map((h) => DropdownMenuItem(value: h, child: Text(h))).toList(), onChanged: (val) => setM(() => hIda = val!), decoration: const InputDecoration(labelText: 'Horário', border: OutlineInputBorder())), const SizedBox(height: 20),
      ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)), onPressed: () {
        if (v == null) { widget.viagens.add(Viagem(id: '${DateTime.now().millisecondsSinceEpoch}_i', dia: dia, tipo: 'Ida', horario: hIda)); widget.viagens.add(Viagem(id: '${DateTime.now().millisecondsSinceEpoch}_v', dia: dia, tipo: 'Volta', horario: hVolta)); } else { v.dia = dia; v.horario = hIda; }
        widget.onUpdate(); Navigator.pop(context);
      }, child: const Text('Salvar')),
      if (v != null) TextButton(onPressed: () { widget.viagens.remove(v); widget.onUpdate(); Navigator.pop(context); }, child: const Text('Excluir Carona', style: TextStyle(color: Colors.red))), const SizedBox(height: 20),
    ]))));
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> grid = [];
    for (int i = 0; i < widget.viagens.length; i += 2) {
      grid.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _buildCard(widget.viagens[i])), const SizedBox(width: 8),
        if (i + 1 < widget.viagens.length) Expanded(child: _buildCard(widget.viagens[i + 1])) else const Expanded(child: SizedBox()),
      ])));
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: () => _abrirForm(null), child: const Icon(Icons.add)),
      body: ListView(padding: const EdgeInsets.all(12), children: [const Text('Suas Caronas', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)), const SizedBox(height: 16), ...grid]),
    );
  }

  Widget _buildCard(Viagem v) {
    bool cheio = v.passageiros.length >= v.limiteVagas;
    Color corQtd = cheio ? Colors.red : Theme.of(context).colorScheme.primary;
    return Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(onTap: () => _abrirForm(v), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('${v.dia}\n${v.tipo} ${v.horario}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)), Text('(${v.passageiros.length})', style: TextStyle(color: corQtd, fontWeight: FontWeight.bold, fontSize: 16))])), const Divider(),
      ...v.passageiros.map((p) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [Expanded(child: Text('• ${p.nome}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)), GestureDetector(onTap: () { setState(() => v.passageiros.remove(p)); widget.onUpdate(); }, child: const Icon(Icons.close, size: 14, color: Colors.red))]))), const SizedBox(height: 8),
      SizedBox(width: double.infinity, height: 28, child: OutlinedButton(onPressed: cheio ? null : () {
        showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('Adicionar à Carona'), content: SizedBox(width: double.maxFinite, child: ListView.builder(shrinkWrap: true, itemCount: widget.pessoasCadastradas.length, itemBuilder: (ctx, idx) { return ListTile(title: Text(widget.pessoasCadastradas[idx].nome), onTap: () { setState(() => v.passageiros.add(widget.pessoasCadastradas[idx])); widget.onUpdate(); Navigator.pop(context); });}))));
      }, child: const Icon(Icons.add, size: 16))),
    ])));
  }
}

// ==========================================
// ABA 2: CONTATOS
// ==========================================
class ContatosTab extends StatelessWidget {
  final List<Pessoa> pessoas; final VoidCallback onUpdate;
  const ContatosTab({super.key, required this.pessoas, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(label: const Text('Novo Contato'), icon: const Icon(Icons.person_add), onPressed: () {
        final tN = TextEditingController(); final tT = TextEditingController();
        showModalBottomSheet(context: context, isScrollControlled: true, builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Novo Contato', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 16),
          TextField(controller: tN, decoration: const InputDecoration(labelText: 'Nome', border: OutlineInputBorder())), const SizedBox(height: 16),
          TextField(controller: tT, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'WhatsApp (Ex: 12999999999)', border: OutlineInputBorder())), const SizedBox(height: 20),
          ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)), onPressed: () { if(tN.text.isNotEmpty && tT.text.isNotEmpty) { pessoas.add(Pessoa(nome: tN.text, telefone: formatarTelefoneBr(tT.text))); onUpdate(); Navigator.pop(context); } }, child: const Text('Salvar')), const SizedBox(height: 20),
        ])));
      }),
      body: ListView(padding: const EdgeInsets.all(12), children: [const Text('Seus Contatos', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)), const SizedBox(height: 10), ...pessoas.asMap().entries.map((e) => ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text(e.value.nome), subtitle: Text("+${e.value.telefone}"), trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () { pessoas.removeAt(e.key); onUpdate(); })))]),
    );
  }
}

// ==========================================
// ABA 3: AJUSTES E MENSAGENS
// ==========================================
class ConfigTab extends StatefulWidget {
  final List<RegraMensagem> regras; final List<Viagem> viagens; final VoidCallback onUpdate; final bool isDark; final Color currentColor; final Function(bool, Color) onThemeChanged;
  const ConfigTab({super.key, required this.regras, required this.viagens, required this.onUpdate, required this.isDark, required this.currentColor, required this.onThemeChanged});
  @override
  State<ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends State<ConfigTab> {
  int _clicks = 0;

  void _mostrarPreviaFiltro(BuildContext context, RegraMensagem regra) {
    List<Pessoa> quemRecebe = obterDestinatarios(regra, widget.viagens, isManual: true);
    String nomes = quemRecebe.map((p) => p.nome).join(', ');
    String aviso = quemRecebe.isEmpty ? "Previsão de Hoje: Ninguém estaria na carona alvo." : "Se disparasse hoje, iria para: $nomes";
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(aviso), duration: const Duration(seconds: 4), behavior: SnackBarBehavior.floating));
  }

  void _abrirConfigRegra(BuildContext context, {RegraMensagem? rExistente, int? idx}) {
    final tM = TextEditingController(text: rExistente?.texto ?? ''); 
    String tD = rExistente?.tipoDia ?? 'Dia da Carona'; 
    String tH = rExistente?.tipoHorario ?? 'Horário Específico'; 
    final tV = TextEditingController(text: rExistente?.valorHorario ?? '');
    String tAlvo = rExistente?.alvoCarona ?? 'Ida';
    String tDFixo = rExistente?.diaFixo ?? 'Segunda';
    
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (ctx) => StatefulBuilder(builder: (ctx, setM) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20), child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Configurar Mensagem', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 16),
      TextField(controller: tM, decoration: const InputDecoration(labelText: 'Mensagem', border: OutlineInputBorder())), const SizedBox(height: 16),
      DropdownButtonFormField<String>(value: tD, items: ['Dia Anterior', 'Dia da Carona', 'Fixo'].map((s)=>DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: (v)=>setM(()=>tD=v!), decoration: const InputDecoration(labelText: 'Quando?', border: OutlineInputBorder())), const SizedBox(height: 16),
      if (tD == 'Fixo') DropdownButtonFormField<String>(value: tDFixo, items: ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'].map((s)=>DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: (v)=>setM(()=>tDFixo=v!), decoration: const InputDecoration(labelText: 'Qual dia da semana?', border: OutlineInputBorder())), if (tD == 'Fixo') const SizedBox(height: 16),
      DropdownButtonFormField<String>(value: tAlvo, items: ['Ida', 'Volta'].map((s)=>DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: (v)=>setM(()=>tAlvo=v!), decoration: const InputDecoration(labelText: 'Qual carona?', border: OutlineInputBorder())), const SizedBox(height: 16),
      DropdownButtonFormField<String>(value: tH, items: ['Horário Específico', 'Minutos Depois'].map((s)=>DropdownMenuItem(value: s, child: Text(s))).toList(), onChanged: (v)=>setM(()=>tH=v!), decoration: const InputDecoration(labelText: 'Tipo de Horário', border: OutlineInputBorder())), const SizedBox(height: 16),
      TextField(controller: tV, readOnly: tH=='Horário Específico', decoration: InputDecoration(labelText: tH=='Horário Específico'?'Toque para escolher a hora':'Quantos minutos?', border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.access_time)), onTap: tH=='Horário Específico' ? () async { TimeOfDay? p = await showTimePicker(context: context, initialTime: TimeOfDay.now()); if (p!=null) setM(()=>tV.text='${p.hour.toString().padLeft(2,'0')}:${p.minute.toString().padLeft(2,'0')}'); } : null), const SizedBox(height: 20),
      ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)), onPressed: () { 
        if(tM.text.isNotEmpty && tV.text.isNotEmpty) { 
          var n = RegraMensagem(texto: tM.text, tipoDia: tD, diaFixo: tD == 'Fixo' ? tDFixo : null, tipoHorario: tH, valorHorario: tV.text, alvoCarona: tAlvo, ativo: rExistente?.ativo ?? true);
          if (idx != null) widget.regras[idx] = n; else widget.regras.add(n); widget.onUpdate(); Navigator.pop(context); if (n.ativo) _mostrarPreviaFiltro(context, n);
        } 
      }, child: const Text('Salvar')), const SizedBox(height: 20),
    ])))));
  }

  @override
  Widget build(BuildContext context) {
    final cores = [Colors.blue, Colors.greenAccent, Colors.purple, Colors.orange, Colors.red];
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Automações de Mensagem', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey)), const SizedBox(height: 10),
      Card(child: Column(children: [
        ...widget.regras.asMap().entries.map((e) {
          int index = e.key; RegraMensagem r = e.value;
          return ListTile(
            leading: Switch(value: r.ativo, onChanged: (v) { r.ativo = v; widget.onUpdate(); if (v) _mostrarPreviaFiltro(context, r); }),
            title: Text('"${r.texto}"', overflow: TextOverflow.ellipsis),
            subtitle: Text('${r.tipoDia} ${r.diaFixo != null ? "(${r.diaFixo})" : ""} • ${r.tipoHorario == "Minutos Depois" ? "+${r.valorHorario} min" : r.valorHorario}'),
            trailing: PopupMenuButton(onSelected: (val) async {
              if (val == 'env') { 
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tentando envio nativo...'))); 
                int resultado = await executarRegra(r, widget.viagens, isManual: true); 
                if (resultado == -1) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Erro: Conecte o WhatsApp primeiro!'), backgroundColor: Colors.red));
                else if (resultado == -2) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Erro API: Falta de sincronia. Tente Reconectar.'), backgroundColor: Colors.red));
                else if (resultado == 0) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aviso: Ninguém atende aos critérios para viagem HOJE.')));
                else ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sucesso: Mensagem disparada para $resultado pessoa(s)!'), backgroundColor: Colors.green));
              }
              if (val == 'edit') _abrirConfigRegra(context, rExistente: r, idx: index);
              if (val == 'del') { widget.regras.removeAt(index); widget.onUpdate(); }
            }, itemBuilder: (ctx) => [const PopupMenuItem(value: 'env', child: Text('Enviar agora')), const PopupMenuItem(value: 'edit', child: Text('Editar')), const PopupMenuItem(value: 'del', child: Text('Excluir', style: TextStyle(color: Colors.red)))]),
          );
        }),
        ListTile(leading: const Icon(Icons.add, color: Colors.blue), title: const Text('Nova Mensagem', style: TextStyle(color: Colors.blue)), onTap: () => _abrirConfigRegra(context)),
      ])),
      const SizedBox(height: 30), const Text('Aparência', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey)), const SizedBox(height: 10),
      Card(child: Column(children: [
        SwitchListTile(title: const Text('Modo Escuro (OLED)'), value: widget.isDark, onChanged: (v) => widget.onThemeChanged(v, widget.currentColor)),
        const Padding(padding: EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: Text('Cor de Destaque'))),
        Padding(padding: const EdgeInsets.only(bottom: 16), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: cores.map((c) => GestureDetector(onTap: () { widget.onThemeChanged(widget.isDark, c); if (c.value == Colors.greenAccent.value) { _clicks++; if (_clicks >= 3) { _clicks = 0; Navigator.push(context, MaterialPageRoute(builder: (ctx) => TelaSecretaLogs(regras: widget.regras, viagens: widget.viagens))); } } else _clicks = 0; }, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: widget.currentColor.value == c.value ? Border.all(color: widget.isDark ? Colors.white : Colors.black, width: 3) : null)))).toList())),
      ])),
    ]);
  }
}

// ==========================================
// TELA SECRETA: LOGS DO MOTOR
// ==========================================
class TelaSecretaLogs extends StatelessWidget {
  final List<RegraMensagem> regras; final List<Viagem> viagens;
  const TelaSecretaLogs({super.key, required this.regras, required this.viagens});
  
  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> logs = [];
    for (var r in regras) {
      if (!r.ativo) continue;
      if (r.tipoHorario == 'Horário Específico') logs.add({'h': r.valorHorario, 't': r.texto});
      else {
        int m = int.tryParse(r.valorHorario) ?? 0; Set<String> listH = {};
        for (var v in viagens) {
          if (r.alvoCarona == v.tipo) listH.add(formatarMinutos(parseMinutos(v.horario) + m));
        }
        for (var h in listH) logs.add({'h': h, 't': '${r.texto} [+$m min]'});
      }
    }
    logs.sort((a, b) => parseMinutos(a['h']).compareTo(parseMinutos(b['h'])));
    return Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, title: const Text('Motor de Disparo', style: TextStyle(color: Colors.greenAccent)), iconTheme: const IconThemeData(color: Colors.greenAccent)), body: logs.isEmpty ? const Center(child: Text('Nenhum alarme engatilhado.', style: TextStyle(color: Colors.grey))) : ListView.builder(itemCount: logs.length, itemBuilder: (ctx, i) => ListTile(leading: const Icon(Icons.alarm, color: Colors.greenAccent), title: Text(logs[i]['h'], style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)), subtitle: Text(logs[i]['t'], style: const TextStyle(color: Colors.grey)))));
  }
}