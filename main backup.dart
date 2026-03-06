import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

// ==========================================
// FUNÇÕES AUXILIARES DE TEMPO
// ==========================================
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
// LÓGICA DO FILTRO (O Cérebro da Separação)
// ==========================================
List<Pessoa> obterDestinatarios(RegraMensagem regra, List<Viagem> viagens, {bool isManual = false}) {
  DateTime agora = DateTime.now();
  const diasDaSemana = ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'];
  
  String hojeStr = diasDaSemana[agora.weekday - 1]; 
  String amanhaStr = diasDaSemana[agora.weekday % 7]; 

  Map<String, Pessoa> pessoasParaEnviar = {}; 

  for (var viagem in viagens) {
    bool adicionarViagem = false;

    // 1. CHECAGEM DE DIA
    if (regra.tipoDia == 'Dia Anterior') {
      if (viagem.dia == amanhaStr) adicionarViagem = true;
    } 
    else if (regra.tipoDia == 'Dia da Carona') {
      if (viagem.dia == hojeStr) {
        if (regra.alvoCarona == 'Ambos' || regra.alvoCarona == viagem.tipo) {
          adicionarViagem = true;
        }
      }
    } 
    else if (regra.tipoDia == 'Fixo') {
      if (hojeStr == regra.diaFixo && viagem.dia == regra.diaFixo) {
        adicionarViagem = true;
      }
    }

    // 2. CHECAGEM DE HORÁRIO (Se for alarme automático de "Minutos Depois")
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

    // 3. ADICIONA OS PASSAGEIROS DA VIAGEM APROVADA
    if (adicionarViagem) {
      for (var p in viagem.passageiros) {
        pessoasParaEnviar[p.telefone] = p; 
      }
    }
  }

  return pessoasParaEnviar.values.toList();
}

// ==========================================
// FUNÇÃO GLOBAL DE DISPARO
// ==========================================
Future<void> executarRegra(RegraMensagem regra, List<Viagem> viagens, {bool isManual = false}) async {
  List<Pessoa> destinatarios = obterDestinatarios(regra, viagens, isManual: isManual);

  for (var pessoa in destinatarios) {
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:3000/enviar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'numero': pessoa.telefone, 
          'mensagem': regra.texto
        }),
      );
    } catch (e) {
      debugPrint("Erro Termux: $e");
    }
  }
}

// ==========================================
// O UNIVERSO PARALELO (Background)
// ==========================================
@pragma('vm:entry-point')
Future<void> motorDeDisparoBackground(int idAlarme) async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  if (!prefs.containsKey('regras') || !prefs.containsKey('viagens')) return;

  List<RegraMensagem> regras = List<RegraMensagem>.from(
      jsonDecode(prefs.getString('regras')!).map((model) => RegraMensagem.fromJson(model))
  );
  
  List<Viagem> viagens = List<Viagem>.from(
      jsonDecode(prefs.getString('viagens')!).map((model) => Viagem.fromJson(model))
  );

  int idRegra = idAlarme ~/ 100;

  if (idRegra >= regras.length) return;
  RegraMensagem regra = regras[idRegra];

  if (!regra.ativo) return; 

  String dataDeHoje = '${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}';
  String chaveTrava = 'trava_alarme_$idAlarme';
  
  if (prefs.getString(chaveTrava) == dataDeHoje) return; 
  prefs.setString(chaveTrava, dataDeHoje);

  await executarRegra(regra, viagens, isManual: false);
}

// ==========================================
// GERENCIADOR DE ALARMES DO SISTEMA
// ==========================================
Future<void> atualizarAlarmesNoSistema(List<RegraMensagem> regras, List<Viagem> viagens) async {
  for (int i = 0; i < 200; i++) {
    AndroidAlarmManager.cancel(i); 
  }

  for (int i = 0; i < regras.length; i++) {
    var regra = regras[i];
    
    if (!regra.ativo) continue;
    
    if (regra.tipoHorario == 'Horário Específico') {
      List<String> partes = regra.valorHorario.split(':');
      int h = int.parse(partes[0]);
      int m = int.parse(partes[1]);
      
      DateTime now = DateTime.now();
      DateTime scheduledDate = DateTime(now.year, now.month, now.day, h, m);
      
      if (scheduledDate.isBefore(now)) {
        scheduledDate = scheduledDate.add(const Duration(days: 1));
      }

      await AndroidAlarmManager.periodic(
        const Duration(days: 1),
        (i * 100), 
        motorDeDisparoBackground,
        startAt: scheduledDate, 
        exact: true, 
        wakeup: true, 
        rescheduleOnReboot: true,
      );
    } 
    else if (regra.tipoHorario == 'Minutos Depois') {
      int addMins = int.tryParse(regra.valorHorario) ?? 0;
      Set<String> horariosUnicosParaProgramar = {};

      for (var v in viagens) {
        if (regra.alvoCarona == 'Ambos' || regra.alvoCarona == v.tipo) {
          int minTotal = parseMinutos(v.horario) + addMins;
          horariosUnicosParaProgramar.add(formatarMinutos(minTotal));
        }
      }

      int subId = 1;
      for (var horarioCalculado in horariosUnicosParaProgramar) {
        List<String> partes = horarioCalculado.split(':');
        int h = int.parse(partes[0]);
        int m = int.parse(partes[1]);
        
        DateTime now = DateTime.now();
        DateTime scheduledDate = DateTime(now.year, now.month, now.day, h, m);
        
        if (scheduledDate.isBefore(now)) {
          scheduledDate = scheduledDate.add(const Duration(days: 1));
        }

        await AndroidAlarmManager.periodic(
          const Duration(days: 1),
          (i * 100) + subId, 
          motorDeDisparoBackground,
          startAt: scheduledDate, 
          exact: true, 
          wakeup: true, 
          rescheduleOnReboot: true,
        );
        subId++;
      }
    }
  }
}

// ==========================================
// INICIALIZAÇÃO DO APP
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AndroidAlarmManager.initialize();
  runApp(const GerenciadorCaronaApp());
}

// ==========================================
// ESTRUTURAS DE DADOS (Modelos com JSON)
// ==========================================
class Pessoa {
  String nome;
  String telefone;
  
  Pessoa({
    required this.nome, 
    required this.telefone
  });
  
  Map<String, dynamic> toJson() {
    return {
      'nome': nome, 
      'telefone': telefone
    };
  }
  
  factory Pessoa.fromJson(Map<String, dynamic> json) {
    return Pessoa(
      nome: json['nome'], 
      telefone: json['telefone']
    );
  }
}

class Viagem {
  String id;
  String dia;
  String tipo;
  String horario;
  List<Pessoa> passageiros;
  final int limiteVagas = 4;

  Viagem({
    required this.id, 
    required this.dia, 
    required this.tipo, 
    required this.horario, 
    List<Pessoa>? passageiros
  }) : passageiros = passageiros ?? [];
    
  Map<String, dynamic> toJson() {
    return {
      'id': id, 
      'dia': dia, 
      'tipo': tipo, 
      'horario': horario, 
      'passageiros': passageiros.map((p) => p.toJson()).toList()
    };
  }
  
  factory Viagem.fromJson(Map<String, dynamic> json) {
    return Viagem(
      id: json['id'], 
      dia: json['dia'], 
      tipo: json['tipo'], 
      horario: json['horario'], 
      passageiros: (json['passageiros'] as List).map((p) => Pessoa.fromJson(p)).toList()
    );
  }
}

class RegraMensagem {
  String texto;
  String tipoDia; 
  String? diaFixo; 
  String? alvoCarona; 
  String tipoHorario; 
  String valorHorario; 
  bool ativo; 

  RegraMensagem({
    required this.texto, 
    required this.tipoDia, 
    this.diaFixo, 
    this.alvoCarona, 
    required this.tipoHorario, 
    required this.valorHorario, 
    this.ativo = true
  });
  
  Map<String, dynamic> toJson() {
    return {
      'texto': texto, 
      'tipoDia': tipoDia, 
      'diaFixo': diaFixo, 
      'alvoCarona': alvoCarona, 
      'tipoHorario': tipoHorario, 
      'valorHorario': valorHorario, 
      'ativo': ativo
    };
  }
  
  factory RegraMensagem.fromJson(Map<String, dynamic> json) {
    return RegraMensagem(
      texto: json['texto'], 
      tipoDia: json['tipoDia'], 
      diaFixo: json['diaFixo'], 
      alvoCarona: json['alvoCarona'], 
      tipoHorario: json['tipoHorario'], 
      valorHorario: json['valorHorario'], 
      ativo: json['ativo'] ?? true
    );
  }
}

// ==========================================
// APP PRINCIPAL E ESTADO GLOBAL
// ==========================================
class GerenciadorCaronaApp extends StatefulWidget {
  const GerenciadorCaronaApp({super.key});
  
  @override
  State<GerenciadorCaronaApp> createState() => _GerenciadorCaronaAppState();
}

class _GerenciadorCaronaAppState extends State<GerenciadorCaronaApp> {
  bool isOledDark = false;
  Color corPrincipal = Colors.blue; 

  void mudarTema(bool dark, Color cor) { 
    setState(() { 
      isOledDark = dark; 
      corPrincipal = cor; 
    }); 
  }

  @override
  Widget build(BuildContext context) {
    // Lógica do Tema "Hacker/Terminal"
    bool isTerminalMode = corPrincipal.value == Colors.greenAccent.value;
    bool aplicarModoEscuro = isOledDark || isTerminalMode;

    return MaterialApp(
      title: 'Caronas', 
      debugShowCheckedModeBanner: false,
      themeMode: aplicarModoEscuro ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        colorSchemeSeed: corPrincipal, 
        useMaterial3: true, 
        brightness: Brightness.light,
        cardTheme: isTerminalMode ? const CardThemeData(color: Colors.transparent, elevation: 0) : null,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: corPrincipal, 
        useMaterial3: true, 
        brightness: Brightness.dark, 
        scaffoldBackgroundColor: aplicarModoEscuro ? Colors.black : null, 
        cardColor: (isOledDark && !isTerminalMode) ? const Color(0xFF121212) : null,
        // Aplica transparência e tira a sombra das coisas se for modo Terminal
        cardTheme: isTerminalMode ? const CardThemeData(color: Colors.transparent, elevation: 0) : null,
        dividerTheme: isTerminalMode ? DividerThemeData(color: Colors.greenAccent.withOpacity(0.3)) : null,
        listTileTheme: isTerminalMode ? const ListTileThemeData(iconColor: Colors.greenAccent) : null,
      ),
      home: TelaNavegacao(
        onThemeChanged: mudarTema, 
        isDark: aplicarModoEscuro, // Atualiza visualmente o Switch de OLED para bater com a tela
        currentColor: corPrincipal
      ),
    );
  }
}

// ==========================================
// TELA DE NAVEGAÇÃO
// ==========================================
class TelaNavegacao extends StatefulWidget {
  final Function(bool, Color) onThemeChanged;
  final bool isDark;
  final Color currentColor;
  
  const TelaNavegacao({
    super.key, 
    required this.onThemeChanged, 
    required this.isDark, 
    required this.currentColor
  });
  
  @override
  State<TelaNavegacao> createState() => _TelaNavegacaoState();
}

class _TelaNavegacaoState extends State<TelaNavegacao> {
  int _indiceAtual = 0;
  List<Pessoa> bancoContatos = [];
  List<RegraMensagem> bancoRegras = [];
  List<Viagem> viagens = []; 

  @override
  void initState() { 
    super.initState(); 
    _carregarDados(); 
  }

  Future<void> _carregarDados() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (prefs.containsKey('contatos')) {
        bancoContatos = List<Pessoa>.from(
          jsonDecode(prefs.getString('contatos')!).map((m) => Pessoa.fromJson(m))
        );
      } 
      if (prefs.containsKey('regras')) {
        bancoRegras = List<RegraMensagem>.from(
          jsonDecode(prefs.getString('regras')!).map((m) => RegraMensagem.fromJson(m))
        );
      } 
      if (prefs.containsKey('viagens')) {
        viagens = List<Viagem>.from(
          jsonDecode(prefs.getString('viagens')!).map((m) => Viagem.fromJson(m))
        );
      } 
      _ordenarCaronas();
    });
    atualizarAlarmesNoSistema(bancoRegras, viagens);
  }

  Future<void> _salvarDados() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('contatos', jsonEncode(bancoContatos.map((e) => e.toJson()).toList()));
    prefs.setString('regras', jsonEncode(bancoRegras.map((e) => e.toJson()).toList()));
    prefs.setString('viagens', jsonEncode(viagens.map((e) => e.toJson()).toList()));
    
    atualizarAlarmesNoSistema(bancoRegras, viagens);
  }

  void _ordenarCaronas() {
    const diasPeso = {'Segunda': 1, 'Terça': 2, 'Quarta': 3, 'Quinta': 4, 'Sexta': 5, 'Sábado': 6, 'Domingo': 7};
    viagens.sort((a, b) {
      int pesoA = diasPeso[a.dia] ?? 0; 
      int pesoB = diasPeso[b.dia] ?? 0;
      if (pesoA != pesoB) return pesoA.compareTo(pesoB);
      
      int minutosA = parseMinutos(a.horario);
      int minutosB = parseMinutos(b.horario);
      if (minutosA != minutosB) return minutosA.compareTo(minutosB);
      
      return a.tipo == 'Ida' ? -1 : 1;
    });
  }

  void _atualizarEstadoGeral() { 
    setState(() => _ordenarCaronas()); 
    _salvarDados(); 
  }

  @override
  Widget build(BuildContext context) {
    final abas = [
      DashboardTab(
        viagens: viagens, 
        pessoasCadastradas: bancoContatos, 
        onUpdate: _atualizarEstadoGeral
      ),
      ContatosTab(
        pessoas: bancoContatos, 
        onUpdate: _atualizarEstadoGeral
      ),
      ConfigTab(
        regras: bancoRegras, 
        viagens: viagens, 
        onUpdate: () { 
          setState((){}); 
          _salvarDados(); 
        },
        isDark: widget.isDark, 
        currentColor: widget.currentColor, 
        onThemeChanged: widget.onThemeChanged,
      ),
    ];

    return Scaffold(
      body: SafeArea(child: abas[_indiceAtual]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _indiceAtual,
        onDestinationSelected: (index) {
          setState(() {
            _indiceAtual = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined), 
            selectedIcon: Icon(Icons.dashboard), 
            label: 'Caronas'
          ),
          NavigationDestination(
            icon: Icon(Icons.contacts_outlined), 
            selectedIcon: Icon(Icons.contacts), 
            label: 'Contatos'
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined), 
            selectedIcon: Icon(Icons.settings), 
            label: 'Ajustes'
          ),
        ],
      ),
    );
  }
}

// ==========================================
// ABA 1: DASHBOARD DE CARONAS DINÂMICAS
// ==========================================
class DashboardTab extends StatefulWidget {
  final List<Viagem> viagens; 
  final List<Pessoa> pessoasCadastradas; 
  final VoidCallback onUpdate;
  
  const DashboardTab({
    super.key, 
    required this.viagens, 
    required this.pessoasCadastradas, 
    required this.onUpdate
  });
  
  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  final List<String> horariosFixos = ['8:00', '10:00', '12:00', '13:30', '15:30', '17:30', '19:00', '21:00', '23:00'];

  void _abrirFormularioCarona() {
    String diaSelecionado = 'Segunda'; 
    String horarioIda = '8:00'; 
    String horarioVolta = '17:30';
    
    showModalBottomSheet(
      context: context, 
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom, 
                left: 20, right: 20, top: 20
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min, 
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nova carona', 
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)
                  ), 
                  const SizedBox(height: 16),
                  
                  DropdownButtonFormField<String>(
                    value: diaSelecionado, 
                    decoration: const InputDecoration(labelText: 'Dia da Semana', border: OutlineInputBorder()),
                    items: ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'].map((d) {
                      return DropdownMenuItem(value: d, child: Text(d));
                    }).toList(), 
                    onChanged: (val) {
                      setModalState(() => diaSelecionado = val!);
                    },
                  ), 
                  const SizedBox(height: 16),
                  
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: horarioIda, 
                          decoration: const InputDecoration(
                            labelText: 'Horário Ida', 
                            border: OutlineInputBorder(), 
                            prefixIcon: Icon(Icons.sunny)
                          ),
                          items: horariosFixos.map((h) {
                            return DropdownMenuItem(value: h, child: Text(h));
                          }).toList(), 
                          onChanged: (val) {
                            setModalState(() => horarioIda = val!);
                          },
                        ),
                      ), 
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: horarioVolta, 
                          decoration: const InputDecoration(
                            labelText: 'Horário Volta', 
                            border: OutlineInputBorder(), 
                            prefixIcon: Icon(Icons.nightlight_round)
                          ),
                          items: horariosFixos.map((h) {
                            return DropdownMenuItem(value: h, child: Text(h));
                          }).toList(), 
                          onChanged: (val) {
                            setModalState(() => horarioVolta = val!);
                          },
                        ),
                      ),
                    ],
                  ), 
                  const SizedBox(height: 20),
                  
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                    onPressed: () {
                      widget.viagens.add(Viagem(
                        id: '${DateTime.now().millisecondsSinceEpoch}_ida', 
                        dia: diaSelecionado, 
                        tipo: 'Ida', 
                        horario: horarioIda
                      ));
                      widget.viagens.add(Viagem(
                        id: '${DateTime.now().millisecondsSinceEpoch}_volta', 
                        dia: diaSelecionado, 
                        tipo: 'Volta', 
                        horario: horarioVolta
                      ));
                      widget.onUpdate(); 
                      Navigator.pop(context);
                    },
                    child: const Text('Salvar'),
                  ), 
                  const SizedBox(height: 20),
                ],
              ),
            );
          }
        );
      }
    );
  }

  void _abrirEdicaoCarona(Viagem viagem) {
    String diaSelecionado = viagem.dia; 
    String tipoSelecionado = viagem.tipo; 
    String horarioSelecionado = viagem.horario;
    
    List<String> horariosOpcoes = List.from(horariosFixos);
    if (!horariosOpcoes.contains(horarioSelecionado)) { 
      horariosOpcoes.add(horarioSelecionado); 
      horariosOpcoes.sort(); 
    }

    showModalBottomSheet(
      context: context, 
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom, 
                left: 20, right: 20, top: 20
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min, 
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Editar carona', 
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)
                  ), 
                  const SizedBox(height: 16),
                  
                  DropdownButtonFormField<String>(
                    value: diaSelecionado, 
                    decoration: const InputDecoration(labelText: 'Dia da Semana', border: OutlineInputBorder()),
                    items: ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'].map((d) {
                      return DropdownMenuItem(value: d, child: Text(d));
                    }).toList(), 
                    onChanged: (val) {
                      setModalState(() => diaSelecionado = val!);
                    },
                  ), 
                  const SizedBox(height: 16),
                  
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: tipoSelecionado, 
                          decoration: const InputDecoration(labelText: 'Tipo', border: OutlineInputBorder()),
                          items: ['Ida', 'Volta'].map((t) {
                            return DropdownMenuItem(value: t, child: Text(t));
                          }).toList(), 
                          onChanged: (val) {
                            setModalState(() => tipoSelecionado = val!);
                          },
                        ),
                      ), 
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: horarioSelecionado, 
                          decoration: const InputDecoration(
                            labelText: 'Horário', 
                            border: OutlineInputBorder(), 
                            prefixIcon: Icon(Icons.access_time)
                          ),
                          items: horariosOpcoes.map((h) {
                            return DropdownMenuItem(value: h, child: Text(h));
                          }).toList(), 
                          onChanged: (val) {
                            setModalState(() => horarioSelecionado = val!);
                          },
                        ),
                      ),
                    ],
                  ), 
                  const SizedBox(height: 20),
                  
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent, 
                      minimumSize: const Size(double.infinity, 50)
                    ),
                    onPressed: () { 
                      widget.viagens.removeWhere((v) => v.id == viagem.id); 
                      widget.onUpdate(); 
                      Navigator.pop(context); 
                    },
                    icon: const Icon(Icons.delete), 
                    label: const Text('Excluir carona'),
                  ), 
                  const SizedBox(height: 8),
                  
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                    onPressed: () {
                      viagem.dia = diaSelecionado; 
                      viagem.tipo = tipoSelecionado; 
                      viagem.horario = horarioSelecionado;
                      widget.onUpdate(); 
                      Navigator.pop(context);
                    },
                    child: const Text('Salvar'),
                  ), 
                  const SizedBox(height: 20),
                ],
              ),
            );
          }
        );
      }
    );
  }

  void _adicionarPassageiro(Viagem viagem) {
    if (widget.pessoasCadastradas.isEmpty) { 
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cadastre contatos primeiro!'))
      ); 
      return; 
    }
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Adicionar à Carona'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true, 
              itemCount: widget.pessoasCadastradas.length,
              itemBuilder: (context, index) {
                final p = widget.pessoasCadastradas[index];
                final jaEstaNaCarona = viagem.passageiros.contains(p);
                
                return ListTile(
                  title: Text(p.nome),
                  trailing: jaEstaNaCarona 
                    ? const Icon(Icons.check_circle, color: Colors.green) 
                    : const Icon(Icons.add_circle_outline),
                  onTap: () { 
                    if (!jaEstaNaCarona) { 
                      setState(() {
                        viagem.passageiros.add(p);
                      }); 
                      widget.onUpdate(); 
                      Navigator.pop(context); 
                    } 
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildCardViagem(Viagem viagem) {
    bool carroCheio = viagem.passageiros.length >= viagem.limiteVagas;
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween, 
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _abrirEdicaoCarona(viagem), 
                    borderRadius: BorderRadius.circular(4), 
                    child: Text(
                      '${viagem.dia}\n${viagem.tipo} ${viagem.horario}', 
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)
                    )
                  )
                ),
                Text(
                  '(${viagem.passageiros.length})', 
                  style: TextStyle(
                    fontWeight: FontWeight.bold, 
                    color: carroCheio ? Colors.redAccent : Theme.of(context).colorScheme.primary
                  )
                ),
              ],
            ), 
            const Divider(),
            ...viagem.passageiros.map((p) => Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '• ${p.nome}', 
                    overflow: TextOverflow.ellipsis, 
                    style: const TextStyle(fontSize: 13)
                  )
                ),
                GestureDetector(
                  onTap: () { 
                    setState(() {
                      viagem.passageiros.remove(p);
                    }); 
                    widget.onUpdate(); 
                  }, 
                  child: const Icon(Icons.close, size: 16, color: Colors.redAccent)
                )
              ],
            )), 
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity, 
              height: 30, 
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: EdgeInsets.zero), 
                onPressed: carroCheio ? null : () => _adicionarPassageiro(viagem), 
                child: const Icon(Icons.add, size: 18)
              )
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> linhas = [];
    for (int i = 0; i < widget.viagens.length; i += 2) {
      linhas.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start, 
            children: [
              Expanded(child: _buildCardViagem(widget.viagens[i])), 
              const SizedBox(width: 8),
              if (i + 1 < widget.viagens.length) 
                Expanded(child: _buildCardViagem(widget.viagens[i + 1])) 
              else 
                Expanded(child: Container()), 
            ]
          ),
        ),
      );
    }
    
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _abrirFormularioCarona, 
        child: const Icon(Icons.add)
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 16.0, top: 8.0), 
            child: Text(
              'Suas Caronas', 
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)
            )
          ),
          if (widget.viagens.isEmpty) 
            const Padding(
              padding: EdgeInsets.only(top: 80.0), 
              child: Center(
                child: Text(
                  'Nenhuma carona.\nClique no + para criar.', 
                  textAlign: TextAlign.center, 
                  style: TextStyle(color: Colors.grey)
                )
              )
            ) 
          else 
            ...linhas,
        ],
      ),
    );
  }
}

// ==========================================
// ABA 2: CONTATOS
// ==========================================
class ContatosTab extends StatelessWidget {
  final List<Pessoa> pessoas; 
  final VoidCallback onUpdate;
  
  const ContatosTab({
    super.key, 
    required this.pessoas, 
    required this.onUpdate
  });

  String _limparNumero(String num) => num.replaceAll(RegExp(r'[^0-9]'), '');

  void _abrirFormulario({Pessoa? pessoa, int? index, required BuildContext context}) {
    final txtNome = TextEditingController(text: pessoa?.nome ?? '');
    final txtTelefone = TextEditingController(text: pessoa?.telefone ?? '');

    showModalBottomSheet(
      context: context, 
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom, 
            left: 20, right: 20, top: 20
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pessoa == null ? 'Novo Contato' : 'Editar Contato', 
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)
              ), 
              const SizedBox(height: 16),
              
              TextField(
                controller: txtNome, 
                decoration: const InputDecoration(labelText: 'Nome', border: OutlineInputBorder())
              ), 
              const SizedBox(height: 16),
              
              TextField(
                controller: txtTelefone, 
                keyboardType: TextInputType.phone, 
                decoration: const InputDecoration(
                  labelText: 'WhatsApp (Ex: +55 12 99999-9999)', 
                  border: OutlineInputBorder()
                )
              ), 
              const SizedBox(height: 20),
              
              if (pessoa != null && index != null) ...[
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent, 
                    minimumSize: const Size(double.infinity, 50)
                  ),
                  onPressed: () { 
                    pessoas.removeAt(index); 
                    onUpdate(); 
                    Navigator.pop(context); 
                  },
                  icon: const Icon(Icons.delete), 
                  label: const Text('Excluir contato'),
                ), 
                const SizedBox(height: 8),
              ],
              
              ElevatedButton(
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                onPressed: () {
                  if(txtNome.text.isNotEmpty && txtTelefone.text.isNotEmpty) {
                    if (pessoa != null && index != null) { 
                      pessoas[index].nome = txtNome.text; 
                      pessoas[index].telefone = _limparNumero(txtTelefone.text); 
                    } else { 
                      pessoas.add(Pessoa(nome: txtNome.text, telefone: _limparNumero(txtTelefone.text))); 
                    }
                    onUpdate(); 
                    Navigator.pop(context);
                  }
                },
                child: const Text('Salvar'),
              ), 
              const SizedBox(height: 20),
            ],
          ),
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirFormulario(context: context), 
        icon: const Icon(Icons.add), 
        label: const Text('Novo Contato')
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 12.0, top: 20.0, bottom: 10.0), 
            child: Text(
              'Seus Contatos', 
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)
            )
          ),
          Expanded(
            child: pessoas.isEmpty 
              ? const Center(child: Text('Nenhum contato cadastrado.'))
              : ListView.builder(
                  itemCount: pessoas.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      onTap: () => _abrirFormulario(context: context, pessoa: pessoas[index], index: index),
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(pessoas[index].nome), 
                      subtitle: Text(pessoas[index].telefone),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// ABA 3: CONFIGURAÇÕES E EASTER EGG
// ==========================================
class ConfigTab extends StatefulWidget {
  final List<RegraMensagem> regras; 
  final List<Viagem> viagens; 
  final VoidCallback onUpdate;
  final bool isDark; 
  final Color currentColor; 
  final Function(bool, Color) onThemeChanged;

  const ConfigTab({
    super.key, 
    required this.regras, 
    required this.viagens, 
    required this.onUpdate, 
    required this.isDark, 
    required this.currentColor, 
    required this.onThemeChanged
  });

  @override
  State<ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends State<ConfigTab> {
  int _cliquesSecretos = 0; // EASTER EGG AGORA É NO VERDE ACCENT

  void _abrirConfigRegra(BuildContext context, {RegraMensagem? regraExistente, int? index}) {
    showModalBottomSheet(
      context: context, 
      isScrollControlled: true,
      builder: (context) => FormularioRegra(
        regraExistente: regraExistente,
        onSalvar: (novaRegra) {
          if (index != null) { 
            widget.regras[index] = novaRegra; 
          } else { 
            widget.regras.add(novaRegra); 
          }
          widget.onUpdate();
        },
      ),
    );
  }

  void _mostrarPreviaFiltro(BuildContext context, RegraMensagem regra) {
    List<Pessoa> quemRecebe = obterDestinatarios(regra, widget.viagens, isManual: true);
    String nomes = quemRecebe.map((p) => p.nome).join(', ');
    
    String aviso = quemRecebe.isEmpty 
      ? "Filtro: Ninguém receberia essa mensagem se ela ativasse hoje." 
      : "Filtro de hoje (Preview): $nomes.";
      
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(aviso), 
        duration: const Duration(seconds: 4), 
        behavior: SnackBarBehavior.floating
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    // Nova paleta com o verde accent de terminal
    final paleta = [Colors.blue, Colors.greenAccent, Colors.purple, Colors.orange, Colors.redAccent];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Automações de Mensagem', 
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey)
        ), 
        const SizedBox(height: 10),
        
        Card(
          child: Column(
            children: [
              ...widget.regras.asMap().entries.map((entry) {
                int index = entry.key; 
                RegraMensagem r = entry.value;
                
                String descDia = r.tipoDia == 'Fixo' ? 'Toda ${r.diaFixo}' : r.tipoDia;
                if (r.tipoDia == 'Dia da Carona' && r.alvoCarona != null) {
                  descDia += ' (${r.alvoCarona})';
                }
                
                String descHora = r.tipoHorario == 'Minutos Depois' 
                  ? '${r.valorHorario} min após a carona' 
                  : 'às ${r.valorHorario}';

                return ListTile(
                  leading: Switch(
                    value: r.ativo,
                    onChanged: (bool valor) { 
                      r.ativo = valor; 
                      widget.onUpdate(); 
                      if (valor) {
                        _mostrarPreviaFiltro(context, r); 
                      }
                    },
                  ),
                  title: Text(
                    '"${r.texto}"', 
                    overflow: TextOverflow.ellipsis, 
                    style: TextStyle(
                      decoration: r.ativo ? null : TextDecoration.lineThrough, 
                      color: r.ativo ? null : Colors.grey
                    )
                  ),
                  subtitle: Text(
                    '$descDia • $descHora', 
                    style: TextStyle(color: r.ativo ? null : Colors.grey)
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'enviar') { 
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Disparando manualmente...'))
                        ); 
                        await executarRegra(r, widget.viagens, isManual: true); 
                      } 
                      else if (value == 'editar') { 
                        _abrirConfigRegra(context, regraExistente: r, index: index); 
                      } 
                      else if (value == 'deletar') { 
                        widget.regras.removeAt(index); 
                        widget.onUpdate(); 
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'enviar', 
                        child: Row(
                          children: [
                            Icon(Icons.send, color: Colors.green, size: 20), 
                            SizedBox(width: 8), 
                            Text('Enviar agora', style: TextStyle(color: Colors.green))
                          ]
                        )
                      ),
                      const PopupMenuItem(
                        value: 'editar', 
                        child: Text('Editar')
                      ),
                      const PopupMenuItem(
                        value: 'deletar', 
                        child: Text('Deletar', style: TextStyle(color: Colors.redAccent))
                      ),
                    ],
                  ),
                );
              }),
              ListTile(
                leading: const Icon(Icons.add, color: Colors.blue), 
                title: const Text('Configurar mensagem', style: TextStyle(color: Colors.blue)), 
                onTap: () => _abrirConfigRegra(context)
              )
            ],
          ),
        ),
        
        const SizedBox(height: 30),
        const Text(
          'Aparência', 
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey)
        ), 
        const SizedBox(height: 10),
        
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Modo Escuro (OLED)'), 
                value: widget.isDark, 
                onChanged: (value) => widget.onThemeChanged(value, widget.currentColor)
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), 
                child: Align(alignment: Alignment.centerLeft, child: Text('Cor Destaque'))
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: paleta.map((cor) {
                    bool isSelected = widget.currentColor.value == cor.value;
                    return GestureDetector(
                      onTap: () {
                        widget.onThemeChanged(widget.isDark, cor);
                        
                        // LÓGICA DO EASTER EGG (3 CLIQUES NO VERDE)
                        if (cor.value == Colors.greenAccent.value) {
                          _cliquesSecretos++;
                          if (_cliquesSecretos >= 3) {
                            _cliquesSecretos = 0; 
                            Navigator.push(
                              context, 
                              MaterialPageRoute(builder: (context) => TelaSecretaLogs(regras: widget.regras, viagens: widget.viagens))
                            );
                          }
                        } else { 
                          _cliquesSecretos = 0; 
                        }
                      },
                      child: Container(
                        width: 40, 
                        height: 40, 
                        decoration: BoxDecoration(
                          color: cor, 
                          shape: BoxShape.circle, 
                          border: isSelected ? Border.all(color: widget.isDark ? Colors.white : Colors.black, width: 3) : null
                        )
                      ),
                    );
                  }).toList(),
                ),
              )
            ],
          ),
        )
      ],
    );
  }
}

// ==========================================
// WIDGET: FORMULÁRIO DE CRIAR/EDITAR REGRA
// ==========================================
class FormularioRegra extends StatefulWidget {
  final RegraMensagem? regraExistente; 
  final Function(RegraMensagem) onSalvar;
  
  const FormularioRegra({
    super.key, 
    this.regraExistente, 
    required this.onSalvar
  });
  
  @override
  State<FormularioRegra> createState() => _FormularioRegraState();
}

class _FormularioRegraState extends State<FormularioRegra> {
  final _txtMensagem = TextEditingController(); 
  final _txtValorHorario = TextEditingController();
  
  String _tipoDia = 'Dia Anterior'; 
  String? _diaFixo = 'Segunda'; 
  String _alvoCarona = 'Ambos'; 
  String _tipoHorario = 'Horário Específico';

  @override
  void initState() {
    super.initState();
    if (widget.regraExistente != null) {
      _txtMensagem.text = widget.regraExistente!.texto; 
      _tipoDia = widget.regraExistente!.tipoDia; 
      _diaFixo = widget.regraExistente!.diaFixo ?? 'Segunda';
      _alvoCarona = widget.regraExistente!.alvoCarona ?? 'Ambos'; 
      _tipoHorario = widget.regraExistente!.tipoHorario; 
      _txtValorHorario.text = widget.regraExistente!.valorHorario;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool usarRelogio = _tipoHorario == 'Horário Específico';
    
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom, 
        left: 20, right: 20, top: 20
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min, 
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.regraExistente == null ? 'Configurar mensagem' : 'Editar mensagem', 
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)
            ), 
            const SizedBox(height: 16),
            
            TextField(
              controller: _txtMensagem, 
              decoration: const InputDecoration(
                labelText: 'Mensagem (Ex: Caroninha amanhã?)', 
                border: OutlineInputBorder()
              )
            ), 
            const SizedBox(height: 16),
            
            DropdownButtonFormField<String>(
              value: _tipoDia, 
              decoration: const InputDecoration(labelText: 'Quando acionar?', border: OutlineInputBorder()),
              items: ['Dia Anterior', 'Dia da Carona', 'Fixo'].map((String v) {
                return DropdownMenuItem(value: v, child: Text(v));
              }).toList(),
              onChanged: (val) {
                setState(() { 
                  _tipoDia = val!; 
                  if (_tipoDia == 'Fixo' && _tipoHorario == 'Minutos Depois') { 
                    _tipoHorario = 'Horário Específico'; 
                    _txtValorHorario.clear(); 
                  } 
                });
              },
            ),
            
            if (_tipoDia == 'Fixo') ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: _diaFixo, 
                decoration: const InputDecoration(labelText: 'Qual dia da semana?', border: OutlineInputBorder()),
                items: ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'].map((String v) {
                  return DropdownMenuItem(value: v, child: Text(v));
                }).toList(), 
                onChanged: (val) {
                  setState(() => _diaFixo = val);
                },
              ),
            ],
            
            if (_tipoDia == 'Dia da Carona') ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: _alvoCarona, 
                decoration: const InputDecoration(labelText: 'Qual carona?', border: OutlineInputBorder()),
                items: ['Ida', 'Volta', 'Ambos'].map((String v) {
                  return DropdownMenuItem(value: v, child: Text(v));
                }).toList(), 
                onChanged: (val) {
                  setState(() => _alvoCarona = val!);
                },
              ),
            ],
            
            const SizedBox(height: 16),
            
            DropdownButtonFormField<String>(
              value: _tipoHorario, 
              decoration: const InputDecoration(labelText: 'Qual horário?', border: OutlineInputBorder()),
              items: (_tipoDia == 'Fixo' ? ['Horário Específico'] : ['Horário Específico', 'Minutos Depois']).map((String v) {
                return DropdownMenuItem(value: v, child: Text(v));
              }).toList(),
              onChanged: (val) {
                setState(() { 
                  _tipoHorario = val!; 
                  _txtValorHorario.clear(); 
                });
              },
            ),
            
            const SizedBox(height: 10),
            
            TextField(
              controller: _txtValorHorario, 
              readOnly: usarRelogio, 
              keyboardType: usarRelogio ? null : TextInputType.number,
              decoration: InputDecoration(
                labelText: usarRelogio ? 'Toque para escolher a hora' : 'Quantos minutos? (Ex: 60)', 
                border: const OutlineInputBorder(), 
                prefixIcon: Icon(usarRelogio ? Icons.access_time : Icons.timer)
              ),
              onTap: () async {
                if (usarRelogio) {
                  TimeOfDay? p = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                  if (p != null) {
                    setState(() {
                      _txtValorHorario.text = '${p.hour.toString().padLeft(2, '0')}:${p.minute.toString().padLeft(2, '0')}';
                    });
                  }
                }
              },
            ),
            
            const SizedBox(height: 20),
            
            ElevatedButton(
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
              onPressed: () {
                if(_txtMensagem.text.isNotEmpty && _txtValorHorario.text.isNotEmpty) {
                  widget.onSalvar(RegraMensagem(
                    texto: _txtMensagem.text, 
                    tipoDia: _tipoDia, 
                    diaFixo: _tipoDia == 'Fixo' ? _diaFixo : null, 
                    alvoCarona: _tipoDia == 'Dia da Carona' ? _alvoCarona : null, 
                    tipoHorario: _tipoHorario, 
                    valorHorario: _txtValorHorario.text, 
                    ativo: widget.regraExistente?.ativo ?? true
                  ));
                  Navigator.pop(context);
                }
              },
              child: const Text('Salvar'),
            ), 
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// TELA SECRETA: LOGS DO MOTOR DE ALARMES
// ==========================================
class TelaSecretaLogs extends StatelessWidget {
  final List<RegraMensagem> regras;
  final List<Viagem> viagens;

  const TelaSecretaLogs({
    super.key, 
    required this.regras, 
    required this.viagens
  });

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> alarmesReaisCalculados = [];

    for (var regra in regras) {
      if (!regra.ativo) continue;

      if (regra.tipoHorario == 'Horário Específico') {
        alarmesReaisCalculados.add({
          'hora': regra.valorHorario, 
          'texto': regra.texto
        });
      } 
      else if (regra.tipoHorario == 'Minutos Depois') {
        int addMins = int.tryParse(regra.valorHorario) ?? 0;
        Set<String> horariosUnicos = {};

        for (var v in viagens) {
          if (regra.alvoCarona == 'Ambos' || regra.alvoCarona == v.tipo) {
            int calcMins = parseMinutos(v.horario) + addMins;
            horariosUnicos.add(formatarMinutos(calcMins));
          }
        }
        for (var h in horariosUnicos) {
          alarmesReaisCalculados.add({
            'hora': h, 
            'texto': '${regra.texto} [Base: Carona + $addMins min]'
          });
        }
      }
    }

    alarmesReaisCalculados.sort((a, b) {
      int minA = parseMinutos(a['hora']);
      int minB = parseMinutos(b['hora']);
      return minA.compareTo(minB);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Motor de Disparo', style: TextStyle(color: Colors.greenAccent)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.greenAccent),
      ),
      backgroundColor: Colors.black,
      body: alarmesReaisCalculados.isEmpty
          ? const Center(
              child: Text(
                'Nenhum alarme no gatilho.', 
                style: TextStyle(color: Colors.grey, fontSize: 16)
              )
            )
          : ListView.builder(
              itemCount: alarmesReaisCalculados.length,
              itemBuilder: (context, index) {
                final alarme = alarmesReaisCalculados[index];
                return ListTile(
                  leading: const Icon(Icons.alarm, color: Colors.greenAccent, size: 30),
                  title: Text(
                    alarme['hora'], 
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)
                  ),
                  subtitle: Text(
                    'Mensagem: "${alarme['texto']}"', 
                    style: const TextStyle(color: Colors.grey)
                  ),
                );
              },
            ),
    );
  }
}