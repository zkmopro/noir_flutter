import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:noir_flutter/src/rust/third_party/mopro_example_app_noir.dart';
import 'package:noir_flutter/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with SingleTickerProviderStateMixin {
  Uint8List? _noirProofResult;
  Uint8List? _noirVerificationKey;
  bool? _noirValid;
  bool isProving = false;
  Exception? _error;
  late TabController _tabController;

  // Controllers to handle user input
  final TextEditingController _controllerNoirA = TextEditingController();
  final TextEditingController _controllerNoirB = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controllerNoirA.text = "5";
    _controllerNoirB.text = "3";
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildNoirTab() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isProving) const CircularProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(_error.toString()),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextFormField(
              controller: _controllerNoirA,
              decoration: const InputDecoration(
                labelText: "Public input `a`",
                hintText: "For example, 3",
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextFormField(
              controller: _controllerNoirB,
              decoration: const InputDecoration(
                labelText: "Public input `b`",
                hintText: "For example, 5",
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: OutlinedButton(
                    onPressed: () async {
                      if (_controllerNoirA.text.isEmpty ||
                          _controllerNoirB.text.isEmpty ||
                          isProving) {
                        return;
                      }
                      setState(() {
                        _error = null;
                        isProving = true;
                      });

                      FocusManager.instance.primaryFocus?.unfocus();
                      Uint8List? noirProofResult;
                      try {
                        var inputs = [
                          _controllerNoirA.text,
                          _controllerNoirB.text
                        ];

                        // Constants for Noir proof generation
                        const bool onChain =
                            true; // Use Keccak for Solidity compatibility
                        const bool lowMemoryMode = false;

                        // Get or generate verification key if not already available
                        if (_noirVerificationKey == null) {
                          setState(() {
                            _error = null;
                          });
                          // Try to load existing VK from assets, or generate new one
                          try {
                            // First try to load existing VK from assets
                            final vkAsset = await rootBundle
                                .load('assets/noir_multiplier2.vk');
                            _noirVerificationKey = vkAsset.buffer.asUint8List();
                          } catch (e) {
                            final circuitPath = await copyAssetToFileSystem(
                                'assets/noir_multiplier2.json');
                            final srsPath = await copyAssetToFileSystem(
                                'assets/noir_multiplier2.srs');
                            // If VK doesn't exist in assets, generate it
                            _noirVerificationKey = await getNoirVerificationKey(
                              circuitPath: circuitPath,
                              srsPath: srsPath,
                              onChain: onChain,
                              lowMemoryMode: lowMemoryMode,
                            );
                          }
                        }

                        final circuitPath = await copyAssetToFileSystem(
                            'assets/noir_multiplier2.json');
                        final srsPath = await copyAssetToFileSystem(
                            'assets/noir_multiplier2.srs');
                        noirProofResult = await generateNoirProof(
                            circuitPath: circuitPath,
                            srsPath: srsPath,
                            inputs: inputs,
                            onChain: onChain,
                            vk: _noirVerificationKey!,
                            lowMemoryMode: lowMemoryMode);
                      } on Exception catch (e) {
                        print("Error: $e");
                        noirProofResult = null;
                        setState(() {
                          _error = e;
                        });
                      }

                      if (!mounted) return;

                      setState(() {
                        isProving = false;
                        _noirProofResult = noirProofResult;
                      });
                    },
                    child: const Text("Generate Proof")),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: OutlinedButton(
                    onPressed: () async {
                      if (_controllerNoirA.text.isEmpty ||
                          _controllerNoirB.text.isEmpty ||
                          isProving) {
                        return;
                      }
                      setState(() {
                        _error = null;
                        isProving = true;
                      });

                      FocusManager.instance.primaryFocus?.unfocus();
                      bool? valid;
                      try {
                        var proofResult = _noirProofResult;
                        var vk = _noirVerificationKey;

                        if (vk == null) {
                          throw Exception(
                              "Verification key not available. Generate proof first.");
                        }

                        final circuitPath = await copyAssetToFileSystem(
                            'assets/noir_multiplier2.json');
                        // Constants for Noir proof verification
                        const bool onChain =
                            true; // Use Keccak for Solidity compatibility
                        const bool lowMemoryMode = false;

                        valid = await verifyNoirProof(
                          circuitPath: circuitPath,
                          proof: proofResult!,
                          onChain: onChain,
                          vk: vk,
                          lowMemoryMode: lowMemoryMode,
                        );
                      } on Exception catch (e) {
                        print("Error: $e");
                        valid = false;
                        setState(() {
                          _error = e;
                        });
                      } on TypeError catch (e) {
                        print("Error: $e");
                        valid = false;
                        setState(() {
                          _error = Exception(e.toString());
                        });
                      }

                      if (!mounted) return;

                      setState(() {
                        _noirValid = valid;
                        isProving = false;
                      });
                    },
                    child: const Text("Verify Proof")),
              ),
            ],
          ),
          if (_noirProofResult != null)
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text('Proof is valid: ${_noirValid ?? false}'),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text('Proof: ${_noirProofResult ?? ""}'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter App With MoPro'),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Noir'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildNoirTab(),
          ],
        ),
      ),
    );
  }
}

/// Copies an asset to a file and returns the file path
Future<String> copyAssetToFileSystem(String assetPath) async {
  final byteData = await rootBundle.load(assetPath);
  final directory = await getApplicationDocumentsDirectory();
  final filename = assetPath.split('/').last;
  final file = File('${directory.path}/$filename');
  await file.writeAsBytes(byteData.buffer.asUint8List());
  return file.path;
}
