import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:Tunein/models/playerstate.dart';
import 'package:Tunein/plugins/AudioReceiverService.dart';
import 'package:Tunein/plugins/nano.dart';
import 'package:Tunein/services/isolates/standardIsolateFunctions.dart';
import 'package:Tunein/utils/ConversionUtils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_notification/media_notification.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart';
import 'package:flutter_isolate/flutter_isolate.dart';
import 'package:Tunein/plugins/upnp.dart' as UPnPPlugin;
import 'package:upnp/upnp.dart';
import 'package:flutter_file_meta_data/flutter_file_meta_data.dart';


class musicServiceIsolate {
  static BehaviorSubject<MapEntry<PlayerState, Tune>> _playerState$ = BehaviorSubject<MapEntry<PlayerState, Tune>>.seeded(
    MapEntry(
      PlayerState.stopped,
      Tune(null, " ", " ", " ", null, null, null, [], null, null, null),
    ),
  );

  BehaviorSubject<MapEntry<PlayerState, Tune>> get playerState$ =>
      _playerState$;


  musicServiceIsolate(){
    WidgetsFlutterBinding.ensureInitialized();
    _initStreams();
  }

  void dispose() {
    newIsolate?.kill(priority: Isolate.immediate);
    newIsolate = null;
    newPluginEnabledIsolate?.kill();
    newPluginEnabledIsolate=null;
  }


  static Map<String, MapEntry<String,String>> filesToServe=Map();

// Temporary attributes

  static Map mapMetaData = Map();

// Isolate  methods and attributes

  SendPort newIsolateSendPort;
  SendPort newPluginEnabledIsolateSendPort;

  Isolate newIsolate;
  FlutterIsolate newPluginEnabledIsolate;

// default port to receive on

  ReceivePort defaultReceivePort = ReceivePort();


  Future<bool> callerCreateIsolate() async {

    ReceivePort receivePort = ReceivePort();


    newIsolate = await Isolate.spawn(
      callbackFunction,
      receivePort.sendPort,
    );


    newIsolateSendPort = await receivePort.first;
    return true;
  }

  Future<bool> callerCreatePluginEnabledIsolate() async {

    ReceivePort receivePort = ReceivePort();


    newPluginEnabledIsolate = await FlutterIsolate.spawn(
      pluginEnabledIsolateCallbackFunction,
      receivePort.sendPort,
    );


    newPluginEnabledIsolateSendPort = await receivePort.first;
    return true;
  }


  Future<dynamic> sendReceive(String messageToBeSent) async {

    ReceivePort port = ReceivePort();


    newIsolateSendPort.send(CrossIsolatesMessage<String>(
        sender: port.sendPort, message: messageToBeSent, command: null));


    return port.first;
  }

  //Sending any crossIsolateMessage

  Future<dynamic> sendCrossIsolateMessage(
      CrossIsolatesMessage messageToBeSent) async {

    ReceivePort port = ReceivePort();


    messageToBeSent = new CrossIsolatesMessage(
        sender: messageToBeSent.sender==null?port.sendPort:messageToBeSent.sender,
        message: messageToBeSent.message,
        command: messageToBeSent.command);

    newIsolateSendPort.send(messageToBeSent);

    return port.first;
  }

  ///This only takes strings as the plugin isolates only take primitive types
  Future<dynamic> sendCrossPluginIsolatesMessage(
      CrossIsolatesMessage messageToBeSent) async {

    ReceivePort port = ReceivePort();


    messageToBeSent = new CrossIsolatesMessage(
        sender: messageToBeSent.sender==null?port.sendPort:messageToBeSent.sender,
        message: messageToBeSent.message,
        command: messageToBeSent.command);

    newPluginEnabledIsolateSendPort.send([messageToBeSent.command,messageToBeSent.message,messageToBeSent.sender]);

    return port.first;
  }

  ///The callback function used in the regular isolate
  static void callbackFunction(SendPort callerSendPort) {

    ReceivePort newIsolateReceivePort = ReceivePort();


    callerSendPort.send(newIsolateReceivePort.sendPort);

    _sendNotFound(HttpResponse response) {
      response.write('Not found');
      response.statusCode = HttpStatus.notFound;
      response.close();
    }

    _handleGet(HttpRequest request) {
      // PENDING: Do more security checks here?
      final String fileID = request.uri.queryParameters["fileID"];
      try{
        String fileUri = fileID!=null?filesToServe[fileID.split(".")[0]].key:null;
        List<String> contentType = filesToServe[fileID.split(".")[0]].value.split("/");
        if(fileUri!=null){
          final File file = new File(fileUri);
          file.exists().then((bool found)  async{
            if (found) {
              request.response.headers.contentType = ContentType(contentType[0]??"audio",contentType[1]??"mpeg");
              //file.openRead().pipe(request.response).catchError((e) {print(e);});
              request.response.contentLength = file.statSync().size;
              await request.response.addStream(file.openRead());
            } else {
              _sendNotFound(request.response);
            }
          });
        }else{
          _sendNotFound(request.response);
        }
      }catch(e){
        print(e);
        _sendNotFound(request.response);
      }

    }

    HttpServer.bind('0.0.0.0', 8089, shared: true).then((HttpServer server) {
      server.listen((request) {
        print("got a request");
        switch (request.method) {
          case 'GET':
            _handleGet(request);
            break;

          default:
            request.response.statusCode = HttpStatus.METHOD_NOT_ALLOWED;
            request.response.close();
        }
      });
    });


    newIsolateReceivePort.listen((dynamic message) {
      CrossIsolatesMessage incomingMessage = message as CrossIsolatesMessage;

      switch(incomingMessage.command){
        case "registerAFileToBeServed":{
          //The message structure is like follow : MapEntry(id, MapEntry(uri, contentType))
          MapEntry<String,MapEntry<String,String>> newMessage = incomingMessage.message;
          filesToServe[newMessage.key]= MapEntry(newMessage.value.key,newMessage.value.value);
          incomingMessage.sender.send(true);
          break;
        }
        case "searchForCastDevices":{
          if(incomingMessage.message!=null){

            StandardIsolateFunctions.searchForCastingDevices((data){
              incomingMessage.sender.send(data);
            });
          }
          break;
        }
        case "readExternalDirectory":{
          if(incomingMessage.message!=null){
            StandardIsolateFunctions.readExtDir(incomingMessage.message,(dataPath){
              incomingMessage.sender.send(dataPath);
            });
          }
          break;
        }
        case "encodeSongsToStringList":{
          if(incomingMessage.message!=null){
            StandardIsolateFunctions.saveSongsToPref(incomingMessage.message,(data){
              incomingMessage.sender.send(data);
            });
          }
          break;
        }

        case "fetchAlbumsFromSongs":{
          if(incomingMessage.message!=null){
            StandardIsolateFunctions.fetchAlbumFromsongs(incomingMessage.message,(data){
              incomingMessage.sender.send(data);
            });
          }
          break;
        }


        case "encodeArtistsToStringList":{
          if(incomingMessage.message!=null){
            StandardIsolateFunctions.saveArtiststoPref(incomingMessage.message,(data){
              incomingMessage.sender.send(data);
            });
          }
          break;
        }

        case "getTopAlbums":{
          if(incomingMessage.message!=null){
            List<dynamic> segmentedMessage = incomingMessage.message as List<dynamic>;
            StandardIsolateFunctions.getTopAlbum(segmentedMessage[0], segmentedMessage[1], segmentedMessage[2],(data){
              incomingMessage.sender.send(data);
            });
          }
          break;
        }

        case "getMostPlayedSongs":{
          if(incomingMessage.message!=null){
            List<dynamic> segmentedMessage = incomingMessage.message as List<dynamic>;
            StandardIsolateFunctions.getMostPlayedSongs(segmentedMessage[0], segmentedMessage[1], segmentedMessage[2],(data){
              incomingMessage.sender.send(data);
            });
          }
          break;
        }
        default:
          break;
      }

      if (incomingMessage.sender != null) {
        incomingMessage.sender.send("OK");
      } else {}
    });
  }

  ///This callback function is used in the plugin enabled isolate
  static void pluginEnabledIsolateCallbackFunction(SendPort callerSendPort) {

    ReceivePort newIsolateReceivePort = ReceivePort();
    StreamSubscription NotificationTimestampSub ;

    AudioReceiverService audioReceiverService = new AudioReceiverService();

    callerSendPort.send(newIsolateReceivePort.sendPort);


    newIsolateReceivePort.listen((dynamic message) {
      WidgetsFlutterBinding.ensureInitialized();
      List<dynamic> incomingMessage = message as List<dynamic>;
      switch(incomingMessage[0] as String){
        case "test":{
          (incomingMessage[2] as SendPort).send(incomingMessage[1] as String);
          break;
        }
        case "getAllTracksMetadata":{
          if(incomingMessage[1]!=null){
            fetchMetadataOfAllTracks(incomingMessage[1],(data){
              (incomingMessage[2] as SendPort).send(data);
            });
          }
          break;
        }

        case "writeImage":{
          if(incomingMessage[1]!=null){
            writeImage(null,incomingMessage[1]).then(
                    (data){
                  (incomingMessage[2] as SendPort).send(data.uri);
                }
            );
          }
          break;
        }

        case "playMusic":{
          if(incomingMessage[1]!=null){
            Map args = json.decode(incomingMessage[1]);
            audioReceiverService.playSong(args['uri'],
              albumArt: args["albumArt"],
              album: args["album"],
              title: args["title"],
              artist: args["artist"],
            ).then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "pauseMusic":{
          if(incomingMessage[1]!=null){
            audioReceiverService.pauseSong().then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "stopMusic":{
          if(incomingMessage[1]!=null){
            audioReceiverService.stopSong().then((data)=>(incomingMessage[2] as SendPort).send(data));

          }
          break;
        }
        case "seekMusic":{
          if(incomingMessage[1]!=null){
            audioReceiverService.seek(double.tryParse(incomingMessage[1])).then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "useAndroidNotification":{
          if(incomingMessage[1]!=null){
            Map args = json.decode(incomingMessage[1]);
            audioReceiverService.useNotification(useNotification: args["useNotification"], cancelWhenPlayingStops: args["cancelWhenNotPlaying"]).then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "showAndroidNotification":{
          if(incomingMessage[1]!=null){
            audioReceiverService.showNotification().then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "hideAndroidNotification":{
          if(incomingMessage[1]!=null){
            audioReceiverService.hideNotification().then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "setItem":{
          if(incomingMessage[1]!=null){
            Map args = json.decode(incomingMessage[1]);
            audioReceiverService.setItem(
              uri: args['uri'],
              albumArt: args["albumArt"],
              album: args["album"],
              title: args["title"],
              artist: args["artist"],
            ).then((data)=>(incomingMessage[2] as SendPort).send(data));
          }
          break;
        }
        case "subscribeToPosition":{
          if(incomingMessage[1]!=null){
            audioReceiverService.onPositionChanges((position) => (incomingMessage[2] as SendPort).send(position));
          }
          break;
        }
        case "subscribeToState":{
          if(incomingMessage[1]!=null){
            audioReceiverService.onStateChanges((state) => (incomingMessage[2] as SendPort).send(state));
          }
          break;
        }
        case "subscribeToplaybackKeys":{
          if(incomingMessage[1]!=null){
            audioReceiverService.onPlaybackKeys((keys) => (incomingMessage[2] as SendPort).send(keys));
          }
          break;
        }
        case "showNotification":{
          if(incomingMessage[1]!=null){
            Map<String, dynamic> convertedMap = json.decode(incomingMessage[1]);
            int BigLayoutIconColor = convertedMap["bigLayoutIconColor"]!=null?int.tryParse(convertedMap["bigLayoutIconColor"]):null;
            show(
              bigLayoutIconColor: BigLayoutIconColor!=null?Color(BigLayoutIconColor):null,
              author: convertedMap["author"]??"",
              bgColor: convertedMap["bgColor"]!=null?Color(int.tryParse(convertedMap["bgColor"])):Colors.white,
              BitmapImage: convertedMap["BitmapImage"]!=null?Uint8List.fromList((convertedMap["BitmapImage"] as List).map((e) => int.tryParse(e.toString())).toList()):null,
              iconColor: convertedMap["iconColor"]!=null?Color(int.tryParse(convertedMap["iconColor"])):Colors.white,
              image: convertedMap["image"],
              play: convertedMap["play"]??false,
              subtitleColor: convertedMap["subtitleColor"]!=null?Color(int.tryParse(convertedMap["subtitleColor"])):Colors.white,
              title: convertedMap["title"],
              titleColor: convertedMap["titleColor"]!=null?Color(int.tryParse(convertedMap["titleColor"])):Colors.white,
              bgImageBackgroundColor: convertedMap["bgImageBackgroundColor"]!=null?Color(int.tryParse(convertedMap["bgImageBackgroundColor"])):Colors.white,
              bgBitmapImage: convertedMap["bgBitmapImage"]!=null?Uint8List.fromList((convertedMap["bgBitmapImage"] as List).map((e) => int.tryParse(e.toString())).toList()):null,
              bgImage: convertedMap["bgImage"],
              callback: (data){
                (incomingMessage[2] as SendPort).send(data);
              }
            );

            if(NotificationTimestampSub==null)NotificationTimestampSub = audioReceiverService.onPositionChanges((position) => setNotificationTimeStamp(ConversionUtils.DurationToStandardTimeDisplay(inputDuration: position)));
          }
          break;
        }
        case "hideNotification":{
          if(incomingMessage[1]!=null){
            hide().then((value) {
              return NotificationTimestampSub.cancel().then((canceled) => (incomingMessage[2] as SendPort).send(value));
            });
          }
          break;
        }
        case "subscribeToNext":{
          if(incomingMessage[1]!=null){
            subscribeToNextButton((value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "subscribeToPrev":{
          if(incomingMessage[1]!=null){
            subscribeToPrevButton((value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "subscribeToPlay":{
          if(incomingMessage[1]!=null){
            subscribeToPlayButton((value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "subscribeToPause":{
          if(incomingMessage[1]!=null){
            subscribeToPauseButton((value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "subscribeToSelect":{
          if(incomingMessage[1]!=null){
            subscribeToSelectButton((value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "setTo":{
          if(incomingMessage[1]!=null){
            setNotificationTo(incomingMessage[1]=="true", (value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "setStatusIcon":{
          if(incomingMessage[1]!=null){
            setNotificationStatusIcon(incomingMessage[1], (value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "setTitle":{
          if(incomingMessage[1]!=null){
            setNotificationTitle(incomingMessage[1], (value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "setSubtitle":{
          if(incomingMessage[1]!=null){
            setNotificationSubTitle(incomingMessage[1], (value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "togglePlaypauseButton":{
          if(incomingMessage[1]!=null){
            toggleNotificationPlayPause((value) => (incomingMessage[2] as SendPort).send(value));
          }
          break;
        }
        case "sdCardPermission":{
          if(incomingMessage[1]!=null){
            getSDCardAndPermissions((value)=>(incomingMessage[2] as SendPort).send(value));
          }
        }
      }
    });
  }

  //FetchingMetadata of all tracks methods

  static fetchMetadataOfAllTracks(List tracks, Function(List) callback) async{
    List _metaData=[];
    for (var track in tracks) {
      var data = await getFileMetaData(track);
      if (data!=null && data[2] != null) {
        if (data[2] is List<int>) {
          var digest = sha1.convert(data[2]).toString();
          writeImage(digest, data[2]);
          data[2] = digest;
          _metaData.add(data);
        } else {
          _metaData.add(data);
        }
      } else {
        _metaData.add(data);
      }
    }
    callback(_metaData);
  }

  static Future getFileMetaData(track) async {

    var value;
    try {
      if (mapMetaData[track] == null) {
        var metaValue = await FlutterFileMetaData.getFileMetaData(track);
        return metaValue;
      } else {
        value = mapMetaData[track];
        return value;
      }
    } catch (e, stack) {

    }

  }

  //flutter_isolate static callback
  static ReceivePort isolateTempPort = ReceivePort();
  static void callback(MapEntry<ReceivePort,String>data) async {

    isolateTempPort.listen((dataSenT) async{
      if(dataSenT!=null){
        MethodChannel platform = MethodChannel('android_app_retain');
        var metaValue = await platform
            .invokeMethod("getMetaData", <String, dynamic>{'filepath': data.value});
        data.key.sendPort.send(metaValue);

      }
    });

  }


  static getSDCardAndPermissions(Function(dynamic) callback)async{
    MethodChannel platform = MethodChannel('android_app_retain');
    platform.setMethodCallHandler((call) {
      switch(call.method){
        case "resolveWithSDCardUri":{
          print("***************************************************");
          print("DATA FROM THE SDCARD URI PERMISSION");
          print(call.arguments);
          if(callback!=null){
            callback(call.arguments);
          }
        }
      }
      return null;
    });
    platform.invokeMethod("getSDCardPermission");

  }

  static Future<String> getLocalPath() async {
    Directory dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static Future<File> getLocalFile() async {
    String path = await getLocalPath();
    return File('$path/filesmetadata.json');
  }

  static Future<File> writeImage(var hash, List<int> image) async {
    String path = await getLocalPath();
    if(hash==null){
      hash = sha1.convert(image).toString();
    }
    File imagefile = File('$path/$hash');
    return imagefile.writeAsBytes(image);
  }


  // Notification Methods

  static show({String title, String author, bool play, String image, List<int> BitmapImage, Color titleColor, Color subtitleColor, Color iconColor, Color bigLayoutIconColor, Color bgColor, String bgImage, List<int> bgBitmapImage, Color bgImageBackgroundColor, Function(dynamic) callback}) async{
    MediaNotification.show(
        title: title??"title",
        author: author??"author",
        play: play??true,
        image: image,
        BitmapImage:
        image == null ? BitmapImage : null,
        titleColor: titleColor,
        subtitleColor: subtitleColor,
        iconColor: iconColor,
        bgImage: bgImage,
        bgBitmapImage: bgBitmapImage,
        bgImageBackgroundColor: bgImageBackgroundColor,
        bigLayoutIconColor: bigLayoutIconColor,
        bgColor:bgColor).then((s){
          callback!=null?callback(s):null;
    });
  }

  static Future hide(){
    try{
      return MediaNotification.hide();
    }on PlatformException{
      //
    }
  }
  static setNotificationTimeStamp(String timeStamp) async{
    MediaNotification.setTimestamp(timeStamp);
  }

  static subscribeToPlayButton(Function(dynamic) callback) async{
    MediaNotification.setListener('play', (){
      callback(true);
    });
  }

  static subscribeToNextButton(Function(dynamic) callback) async{
    MediaNotification.setListener('next', (){
      callback(true);
    });
  }

  static subscribeToPrevButton(Function(dynamic) callback) async{
    MediaNotification.setListener('prev', (){
      callback(true);
    });
  }

  static subscribeToSelectButton(Function(dynamic) callback) async{
    MediaNotification.setListener('select', (){
      callback(true);
    });
  }

  static subscribeToPauseButton(Function(dynamic) callback) async{
    MediaNotification.setListener('pause', (){
      callback(true);
    });
  }

  static setNotificationTo(bool value, Function(dynamic) callback) async {
    MediaNotification.setTo(value).then(
        (data){
          callback(data);
        }
    );
  }

  static setNotificationTitle(String value, Function(dynamic) callback) async{
    MediaNotification.setTitle(value).then(
            (data){
          callback(data);
        }
    );
  }

  static setNotificationSubTitle(String value, Function(dynamic) callback) async{
    MediaNotification.setSubtitle(value).then(
            (data){
          callback(data);
        }
    );
  }

  static setNotificationStatusIcon(String value, Function(dynamic) callback) async{
    MediaNotification.setStatusIcon(value).then(
            (data){
          callback(data);
        }
    );
  }

  static toggleNotificationPlayPause(Function(dynamic) callback) async{
    MediaNotification.togglePlayPause().then(
            (data){
          callback(data);
        }
    );
  }

  void _initStreams() {
    _playerState$.listen((data){
      CrossIsolatesMessage messageToBeSent = new CrossIsolatesMessage<MapEntry<PlayerState,Tune>>(
          sender: null,
          message: data,
          command: "UPlayerstate");
      defaultReceivePort.sendPort.send(messageToBeSent);
    });
  }
}

//
// Helper class
//
class CrossIsolatesMessage<T> {
  final SendPort sender;
  final T message;
  final String command;

  CrossIsolatesMessage({
    @required this.command,
    @required this.sender,
    this.message,
  });
}
