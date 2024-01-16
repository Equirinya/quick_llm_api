import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:langchain/langchain.dart';
import 'package:langchain_google/langchain_google.dart';
import 'package:langchain_mistralai/langchain_mistralai.dart';
import 'package:langchain_openai/langchain_openai.dart';
import 'dart:html' as html;

//flutter build web -o ./docs/

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quick LLM API Tester',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyan, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  //$ input / output per 1000 tokens
  final Map<String, (double, double)> openAIPrices = const {
    "gpt-4-vision-preview": (0.01, 0.03),
    "gpt-4-1106-preview": (0.01, 0.03),
    "gpt-3.5-turbo-1106": (0.0010, 0.0020),
  };

  //$ input / output per 1000 chars
  //$0.0025 / image
  final Map<String, (double, double)> googlePrices = const {
    "gemini-pro-vision": (0.00025, 0.0005),
    "gemini-pro": (0.00025, 0.0005),
  };

  //€ input / output per 1000 tokens
  final Map<String, (double, double)> mistralPrices = const {
    "mistral-medium": (0.0025, 0.0075),
    "mistral-small": (0.0006, 0.0018),
    "mistral-tiny": (0.00014, 0.00042),
  };

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  List<(ChatMessage, double, String?, List<int>?)> messages = List.empty(growable: true); //message, price
  BaseChatModel? chatModel;
  String selectedModel = "";
  int contextStartIndex = 0;
  double? currentPrice;
  int tokens = 0;
  int maxTokens = 4096;
  final storage = const FlutterSecureStorage();
  bool initialized = false;

  TextEditingController textController = TextEditingController();

  List<String> providers = ["OpenAI", "Google", "Mistral"];
  String? openAIKey;
  String? googleKey;
  String? mistralKey;
  List<String>? openAIModels;
  List<String>? googleModels;
  List<String>? mistralModels;

  List<(Uint8List, String, bool)> images = List.empty(growable: true);
  List<int> currentImages = List.empty(growable: true);

  @override
  void initState() {
    html.document.onPaste.listen((event) {
      if (event.clipboardData?.files?.isNotEmpty ?? false) {
        for (var file in event.clipboardData!.files!) {
          if ([
            'image/png',
            'image/jpeg',
            'image/jpg'
                'image/gif',
            'image/webp',
          ].contains(file.type)) {
            var reader = html.FileReader();
            reader.readAsArrayBuffer(file);
            reader.onLoadEnd.listen((event) {
              setState(() {
                images.add((reader.result as Uint8List, file.type, true));
                currentImages.add(images.length - 1);
              });
            });
          }
        }
      }
    });
    asyncInit();
    super.initState();
  }

  void asyncInit() async {
    bool saveChats = (await storage.read(key: "saveChats") ?? "false") == "true";

    openAIKey = await storage.read(key: "openAIKey");
    googleKey = await storage.read(key: "googleKey");
    mistralKey = await storage.read(key: "mistralKey");

    //TODO
    if (saveChats) {}

    setState(() {
      initialized = true;
    });
  }

  void calculatePrice() async {
    if (chatModel == null) return;
    String text = messages.map((e) => e.$1.contentAsString).join();
    tokens = await chatModel!.countTokens(ChatPromptValue(messages.map((e) => e.$1).toList()));
    print("Tokens: $tokens");

    //TODO: calculate price

    setState(() {});
  }

  void sendMessage() async {
    if (chatModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Please select a chat model first."),
      ));
      return;
    }
    if (currentImages.isNotEmpty && !selectedModel.contains("vision")) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Please select a vision model."),
      ));
      return;
    }
    String message = textController.text.trim();
    textController.clear();
    messages.add((
      HumanChatMessage(
        content: currentImages.isNotEmpty
            ? ChatMessageContent.multiModal([
                ChatMessageContent.text(message),
                for (var imageIndex in currentImages)
                  ChatMessageContent.image(
                    data: base64Encode(images[imageIndex].$1),
                    mimeType: images[imageIndex].$2,
                    imageDetail: images[imageIndex].$3 ? ChatMessageContentImageDetail.high : ChatMessageContentImageDetail.low,
                  )
              ])
            : ChatMessageContent.text(message),
      ),
      0.0,
      message,
      List<int>.from(currentImages)
    ));
    currentImages.clear();
    setState(() {});
    LanguageModelResult<AIChatMessage> response = await chatModel!.invoke(PromptValue.chat(messages.map((e) => e.$1).toList()));
    messages.add((response.firstOutput, 0.0, null, null));
    setState(() {});
  }

  void registerLLMProvider(int provider) async {
    bool saveKey = false;
    var controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.add),
        title: Text("Register ${providers[provider]}"),
        content: StatefulBuilder(
          builder: (context, setState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(hintText: "API Key"),
                ),
                SwitchListTile(
                  title: const Text("Save Key in Browser"),
                  value: saveKey,
                  onChanged: (value) {
                    saveKey = value;
                    setState(() {});
                  },
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              String key = controller.text;
              if (key.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text("Please enter a key."),
                ));
                return;
              }
              switch (provider) {
                case 0:
                  openAIKey = key;
                  if (saveKey) await storage.write(key: "openAIKey", value: key);
                  openAIModels = widget.openAIPrices.keys.toList();
                  break;
                case 1:
                  googleKey = key;
                  if (saveKey) await storage.write(key: "googleKey", value: key);
                  googleModels = widget.googlePrices.keys.toList();
                  break;
                case 2:
                  mistralKey = key;
                  if (saveKey) await storage.write(key: "mistralKey", value: key);
                  mistralModels = widget.mistralPrices.keys.toList();
                  break;
              }
              setState(() {});
              if (mounted) Navigator.pop(context);
            },
            child: const Text("Register"),
          ),
        ],
      ),
    );
  }

  void selectModel(int provider, String model) async {
    switch (provider) {
      case 0:
        chatModel = ChatOpenAI(apiKey: openAIKey!, defaultOptions: ChatOpenAIOptions(model: model, maxTokens: 4096)); //TODO maxTokens
        break;
      case 1:
        chatModel = ChatGoogleGenerativeAI(apiKey: googleKey!, defaultOptions: ChatGoogleGenerativeAIOptions(model: model));
        break;
      case 2:
        chatModel = ChatMistralAI(apiKey: mistralKey!, defaultOptions: ChatMistralAIOptions(model: model));
        break;
    }
    selectedModel = model;
    calculatePrice();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: !initialized
            ? const Center(
                child: CupertinoActivityIndicator(),
              )
            : Row(
                children: [
                  SizedBox(
                    width: MediaQuery.of(context).size.width * 0.2,
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text("Select your LLM Model:"),
                        ),
                        for (var (index, models) in [openAIModels, googleModels, mistralModels].indexed)
                          models == null
                              ? ListTile(
                                  leading: const Icon(Icons.add),
                                  title: Text(providers[index]),
                                  onTap: () => registerLLMProvider(index),
                                )
                              : ExpansionTile(
                                  title: Text(providers[index]),
                                  initiallyExpanded: true,
                                  maintainState: true,
                                  children: [
                                    for (var (mindex, model) in models.indexed)
                                      ListTile(
                                        leading: selectedModel == model ? const Icon(Icons.check) : null,
                                        title: Text(model),
                                        onTap: () => selectModel(index, model),
                                      )
                                  ],
                                ),
                        Spacer(),
                        ListTile(
                          title: const Text("Max Output Tokens:"),
                        ),
                        ListTile(
                          title: TextFormField(
                            maxLength: 4,
                            keyboardType: TextInputType.number,
                            initialValue: maxTokens.toString(),
                            onChanged: (value) {
                              maxTokens = int.parse(value);
                            },
                          ),
                        )
                      ],
                    ),
                  ),
                  VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              bool isHuman = messages[index].$1 is HumanChatMessage;
                              return Align(
                                alignment: isHuman ? Alignment.centerRight : Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: isHuman ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.secondaryContainer,
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SelectableText(
                                          isHuman ? messages[index].$3! : messages[index].$1.contentAsString,
                                          style: TextStyle(
                                              color: isHuman
                                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                                  : Theme.of(context).colorScheme.onSecondaryContainer),
                                        ),
                                        if (isHuman)
                                          SingleChildScrollView(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                for (var imageIndex in messages[index].$4!)
                                                  Container(
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(8),
                                                      color: Theme.of(context).colorScheme.outline,
                                                    ),
                                                    padding: const EdgeInsets.all(1),
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(8),
                                                      child: GestureDetector(
                                                        onTap: () {
                                                          showDialog(
                                                            context: context,
                                                            builder: (context) => AlertDialog(
                                                              content: Image.memory(
                                                                images[imageIndex].$1,
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                        child: Image.memory(
                                                          images[imageIndex].$1,
                                                          height: max(MediaQuery.of(context).size.height * 0.1, 100),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          )
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var imageIndex in currentImages)
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Stack(
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          color: Theme.of(context).colorScheme.outline,
                                        ),
                                        padding: const EdgeInsets.all(1),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Image.memory(
                                            images[imageIndex].$1,
                                            height: max(MediaQuery.of(context).size.height * 0.1, 100),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        top: 0,
                                        right: 0,
                                        child: CircleAvatar(
                                          backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
                                          radius: 16,
                                          child: IconButton(
                                            iconSize: 16,
                                            color: Theme.of(context).colorScheme.onTertiaryContainer,
                                            onPressed: () {
                                              setState(() {
                                                currentImages.remove(imageIndex);
                                              });
                                            },
                                            icon: const Icon(Icons.close),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        bottom: 0,
                                        right: 0,
                                        child: IconButton(
                                          iconSize: 16,
                                          color: Theme.of(context).colorScheme.onTertiaryContainer,
                                          onPressed: () {
                                            setState(() {
                                              images[imageIndex] = (images[imageIndex].$1, images[imageIndex].$2, !images[imageIndex].$3);
                                            });
                                          },
                                          icon: Icon(images[imageIndex].$3 ? Icons.hd : Icons.hd_outlined),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.only(left: 16, right: 8, bottom: 16, top: 8),
                          child: Row(
                            children: [
                              Expanded(
                                  child: TextField(
                                enableSuggestions: true,
                                keyboardType: TextInputType.multiline,
                                maxLines: null,
                                decoration: const InputDecoration(
                                  hintText: 'Type a message or paste a picture',
                                ),
                                controller: textController,
                                focusNode: FocusNode(
                                  onKey: (FocusNode node, RawKeyEvent evt) {
                                    if (evt.isControlPressed && evt.logicalKey.keyLabel == 'Enter') {
                                      if (evt is RawKeyDownEvent) {
                                        sendMessage();
                                      }
                                      return KeyEventResult.handled;
                                    }
                                    else {
                                      return KeyEventResult.ignored;
                                    }
                                  },
                                ),
                                // contentInsertionConfiguration: ContentInsertionConfiguration(
                                //   onContentInserted: (KeyboardInsertedContent data) async {
                                //     print("Inserted: ${data.mimeType}");
                                //     if (data.data != null) {
                                //       setState(() {
                                //         images.add(data.data!);
                                //         currentImages.add(images.length - 1);
                                //       });
                                //     }
                                //   },
                                //   allowedMimeTypes: const [
                                //     'image/png',
                                //     'image/jpeg',
                                //     'image/jpg'
                                //     'image/gif',
                                //     'image/webp',
                                //   ],
                                // ),
                              )),
                              IconButton(onPressed: sendMessage, icon: const Icon(Icons.send))
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ));
  }
}
