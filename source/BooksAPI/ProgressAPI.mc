import Toybox.Lang;
import Toybox.Communications;
import Toybox.Time;

class ProgressAPI extends BooksAPI {
  var finalCallback = null;
  var booksStorage = null;
  var bookKeys = null;
  var token = null;
  var serverBookmarks = null;
  // bookId => [абсолютнаяПозицияНаСервере, isFinished]
  var serverState = null;

  //***************************************************************************
  function initialize(finalCallback, booksStorage) {
    self.finalCallback = finalCallback;
    self.booksStorage = booksStorage;
    BooksAPI.initialize();
  }

  //***************************************************************************
  function start() {
    logger.info("Start synchronizing playback progress");
    bookKeys = booksStorage.booksOnDevice.keys();
    if (bookKeys.size() == 0) {
      logger.info(
        "No books on device. Skipping playback progress synchronization"
      );
      finalCallback.invoke(booksStorage);
      return;
    }

    var savedToken = JWTools.getToken();
    if (savedToken == null) {
      var authorisationProcessor = new BooksAuthorisationAPI(
        self.method(:onAuthorisation)
      );
      authorisationProcessor.start();
    } else {
      onAuthorisation(savedToken);
    }
  }

  //***************************************************************************
  function onAuthorisation(token) {
    if (token == null or token.equals("")) {
      var message =
        Application.loadResource(Rez.Strings.notSet) +
        " " +
        Application.loadResource(Rez.Strings.token);
      logger.error(message + ". Playback progress sync missed");
      finalCallback.invoke(booksStorage);
      return;
    }
    self.token = token;
    serverBookmarks = {};
    serverState = {};
    getBookProgressFromServer(0);
  }

  //***************************************************************************
  function getBookProgressFromServer(keyIndex) {
    if (keyIndex < bookKeys.size()) {
      var bookId = bookKeys[keyIndex];
      logger.info("Start playback progress query for the book: " + bookId);
      var url = api_url + "/me/progress/" + bookId;
      WebRequest.makeWebRequest(
        url,
        null,
        {
          method => Communications.HTTP_REQUEST_METHOD_GET,
          :headers => {
            "Content-Type" => Communications.REQUEST_CONTENT_TYPE_URL_ENCODED,
            "Authorization" => "Bearer " + token,
          },
          :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
          :context => keyIndex,
        },
        self.method(:onGetBookProgressFromServer)
      );
    } else {
      logger.info("Completed receiving playback progress from server");
      bookmarksProcessing();
    }
  }

  //***************************************************************************
  function onGetBookProgressFromServer(code, data, keyIndex) {
    var bookId = bookKeys[keyIndex];
    if (code == 200) {
      var currentProgress = data["currentTime"].toLong();
      var progressTime = data["lastUpdate"].toLong() / 1000;

      var isFinished = false;
      if (data["isFinished"] != null) {
        isFinished = data["isFinished"];
      }
      serverState[bookId] = [currentProgress, isFinished];

      var serverBookmark = ContentProcessor.bookmarkFromAbsolutePosition(
        bookId,
        currentProgress,
        progressTime
      );

      if (serverBookmark instanceof Lang.Array) {
        logger.info(
          "Playback progress received for the book: " +
            bookId +
            " progress " +
            serverBookmark
        );
        serverBookmarks[bookId] = serverBookmark;
      }
    } else {
      logger.info("Unable to get progress for the book: " + bookId);
    }
    keyIndex += 1;
    getBookProgressFromServer(keyIndex);
  }

  //***************************************************************************
  function bookmarksProcessing() {
    // Работаем с закладками на устройстве и полученными с сервера
    // готовим данные для передачи на сервер

    var webBooksId = [];
    var bookmarksToUpload = [];
    var serverBookmarksKeys = serverBookmarks.keys();

    // Перебираем полученные с сервера закладки
    // определяем какие нужно записать на устройство
    // формируем первоначальный список закладок для
    // выгрузки на сервер
    for (var i = 0; i < serverBookmarksKeys.size(); i++) {
      var bookId = serverBookmarksKeys[i];
      var serverBookmark = serverBookmarks[bookId];
      webBooksId.add(bookId);

      var deviceBookmark = booksStorage.getBookmark(bookId);

      if (deviceBookmark == null) {
        // Записываем закладку на устройство
        booksStorage.saveBookmark(bookId, serverBookmark);
      } else {
        var momentDevice = new Time.Moment(deviceBookmark[2]);
        var momentServer = new Time.Moment(serverBookmark[2]);
        if (momentDevice.greaterThan(momentServer)) {
          // Вариант 1: побеждает более свежая отметка времени, но выгрузку
          // блокируем, если она откатила бы прогресс назад или сняла бы
          // отметку "дослушано". Сервер такой защиты не даёт: сравнение в
          // psm.js:232 смотрит ТОЛЬКО на updatedAt, а MediaProgress.js:245
          // сбрасывает isFinished, если currentTime опускается ниже порога.
          //
          // Вариант 2 (не включён, оставлен на будущее): при расхождении
          // отметок времени менее 60 секунд считать их одновременными и
          // выбирать большую позицию - это компенсирует расхождение часов
          // часов и сервера, но отменяет намеренную перемотку назад.
          if (canUploadDeviceBookmark(bookId, deviceBookmark)) {
            bookmarksToUpload.add(
              createBookmarkUploadItem(
                bookId,
                deviceBookmark[0],
                deviceBookmark[1]
              )
            );
            logger.debug(
              "Added playback progress for the book id: " +
                bookId +
                " for uploading to the server:" +
                deviceBookmark
            );
          } else {
            // Прогресс сервера считаем верным - забираем его на устройство.
            // Счётчик прослушивания намеренно НЕ сбрасываем: время
            // прослушивания в статистике не зависит от позиции, оно
            // абсолютно в рамках одного id сессии, поэтому уйдёт
            // при следующей удачной выгрузке без двойного учёта.
            booksStorage.saveBookmark(bookId, serverBookmark);
          }
        } else if (momentServer.greaterThan(momentDevice)) {
          // Записываем закладку на устройство
          booksStorage.saveBookmark(bookId, serverBookmark);
        }
      }
    }

    // Перебираем все закладки на устройстве и если их нет в списке
    // webBooksId, будем отправлять на сервер
    for (var i = 0; i < bookKeys.size(); i++) {
      var bookId = bookKeys[i];
      if (webBooksId.indexOf(bookId) < 0) {
        var deviceBookmark = booksStorage.getBookmark(bookId);
        if (deviceBookmark != null) {
          bookmarksToUpload.add(
            createBookmarkUploadItem(
              bookId,
              deviceBookmark[0],
              deviceBookmark[1]
            )
          );
          logger.debug(
            "Added playback progress for the book id: " +
              bookId +
              " for uploading to the server:" +
              deviceBookmark
          );
        }
      }
    }

    if (bookmarksToUpload.size() > 0) {
      sendBookmarks(bookmarksToUpload);
    } else {
      logger.info("No playback progress information to upload to server");
      finalCallback.invoke(booksStorage);
      return;
    }
  }

  //***************************************************************************
  // Защита от откатов. Возвращает false, если выгрузка закладки устройства
  // ухудшила бы состояние на сервере.
  function canUploadDeviceBookmark(bookId, deviceBookmark) {
    var state = serverState[bookId];
    if (!(state instanceof Lang.Array)) {
      return true;
    }
    var serverPosition = state[0];
    var serverFinished = state[1];

    if (serverFinished) {
      logger.info(
        "Skipping upload for the book: " +
          bookId +
          " - it is finished on the server"
      );
      return false;
    }

    var devicePosition = ContentProcessor.absolutePositionFromBookmark(
      bookId,
      deviceBookmark[0],
      deviceBookmark[1]
    );
    if (devicePosition < serverPosition) {
      logger.info(
        "Skipping upload for the book: " +
          bookId +
          " - device position " +
          devicePosition +
          " is behind the server position " +
          serverPosition
      );
      return false;
    }

    return true;
  }

  //***************************************************************************
  function sendBookmarks(bookmarksToUpload) {
    logger.info("Start uploading playback progress by books to the server");
    var url = getProxyUrl() + "/audiobookshelf/sync_sessions";

    var data = {
      "server" => server_url,
      "token" => token,
      "items" => bookmarksToUpload,
    };

    var uploadedBookIds = [];
    for (var i = 0; i < bookmarksToUpload.size(); i++) {
      uploadedBookIds.add(bookmarksToUpload[i]["libraryItemId"]);
    }

    var options = {
      :method => Communications.HTTP_REQUEST_METHOD_POST,
      :headers => {
        "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
        "Authorization" => "Bearer " + token,
      },
      :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
      :context => uploadedBookIds,
    };
    WebRequest.makeWebRequest(
      url,
      data,
      options,
      self.method(:onSendBookmarks)
    );

    finalCallback.invoke(booksStorage);
    return;
  }

  // **************************************************************************
  function onSendBookmarks(code, data, uploadedBookIds) {
    logger.debug(
      "Result of uploading playback progress. code: " + code + " data" + data
    );
    if (code != 200) {
      // Ключи сессий не сбрасываем: следующая попытка должна уйти
      // с тем же id, чтобы сервер сделал upsert, а не вторую запись.
      return;
    }

    // success=true с progressSynced=false означает, что сессия записана
    // (время прослушивания зачтено), но прогресс сервер счёл более свежим
    // и не применил. Позиция подтянется при следующей синхронизации.
    if (data instanceof Lang.Dictionary and data["results"] instanceof Lang.Array) {
      var results = data["results"];
      for (var i = 0; i < results.size(); i++) {
        if (results[i]["progressSynced"] == false) {
          logger.info(
            "The server kept its own progress for a session: " + results[i]["id"]
          );
        }
      }
    }

    // Сессия принята сервером - следующее прослушивание должно
    // начать новую сессию с нулевым timeListening.
    for (var i = 0; i < uploadedBookIds.size(); i++) {
      BooksStore.rotateListeningSession(uploadedBookIds[i]);
    }
  }

  // **************************************************************************
  function createBookmarkUploadItem(bookId, fileIndex, position) {
    var absolutePosition = ContentProcessor.absolutePositionFromBookmark(
      bookId,
      fileIndex,
      position
    );

    var listening = booksStorage.getListening(bookId);
    var sessionKey = "0";
    var timeListening = 0;
    if (listening instanceof Lang.Array) {
      sessionKey = listening[0];
      timeListening = listening[1];
    }

    var bookmark = booksStorage.getBookmark(bookId);
    var updatedAt = Time.now().value();
    if (bookmark instanceof Lang.Array) {
      updatedAt = bookmark[2];
    }

    var bookInfo = booksStorage.booksOnDevice[bookId];
    var title = "";
    var author = "";
    if (bookInfo != null) {
      title = bookInfo[BooksStore.BOOK_TITLE];
      author = bookInfo[BooksStore.BOOK_AUTHOR];
    }

    return {
      "libraryItemId" => bookId.toString(),
      "currentTime" => absolutePosition,
      // Секунды. Прокси переводит в миллисекунды: 32-битный Number
      // не вмещает миллисекундную метку времени.
      "updatedAt" => updatedAt,
      "duration" => ContentProcessor.totalDuration(bookId),
      "timeListening" => timeListening,
      "sessionKey" => sessionKey,
      "displayTitle" => title,
      "displayAuthor" => author,
    };
  }
}
