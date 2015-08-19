part of monadart;

/// A 'GET' Route annotation.
///
/// Handler methods on [ResourceController]s that handle GET requests must be annotated with this.
const Route httpGet = const Route("get");

/// A 'PUT' Route annotation.
///
/// Handler methods on [ResourceController]s that handle PUT requests must be annotated with this.
const Route httpPut = const Route("put");

/// A 'POST' Route annotation.
///
/// Handler methods on [ResourceController]s that handle POST requests must be annotated with this.
const Route httpPost = const Route("post");

/// A 'DELETE' Route annotation.
///
/// Handler methods on [ResourceController]s that handle DELETE requests must be annotated with this.
const Route httpDelete = const Route("delete");

/// Resource controller handler method metadata for indicating the HTTP method the controller method corresponds to.
///
/// Each [ResourceController] method that is the entry point for an HTTP request must be decorated with an instance
/// of [Route]. See [httpGet], [httpPut], [httpPost] and [httpDelete] for concrete examples.
class Route {
  /// The method that the annotated request handler method corresponds to.
  ///
  /// Case-insensitive.
  final String method;

  final List<String> _parameters;

  const Route(this.method) : this._parameters = null;

  Route.fromRoute(Route annotatedRoute, List<String> parameters)
  : this.method = annotatedRoute.method,
    this._parameters = parameters;

  /// Returns whether or not this [Route] matches a [ResourceRequest].
  bool matchesRequest(ResourceRequest req) {
    if (req.request.method.toLowerCase() != this.method.toLowerCase()) {
      return false;
    }

    if (req.pathParameters == null) {
      if (this._parameters.length == 0) {
        return true;
      }
      return false;
    }

    if (req.pathParameters.length != this._parameters.length) {
      return false;
    }

    for (var id in this._parameters) {
      if (req.pathParameters[id] == null) {
        return false;
      }
    }

    return true;
  }
}

/// Base class for web service handlers.
///
/// Subclasses of this class can process and respond to an HTTP request.
abstract class ResourceController {

  /// The exception handler for a request handler method that generates an HTTP error response.
  ///
  /// The default handler will always respond to the HTTP request with a 500 status code.
  /// There are other exception handlers involved in the process of handling a request,
  /// but once execution enters a handler method (one decorated with [Route]), this exception handler
  /// is in place.
  Function get exceptionHandler => _exceptionHandler;
  void set exceptionHandler(void handler(ResourceRequest resourceRequest, dynamic exceptionOrError, StackTrace stacktrace)) {
    _exceptionHandler = handler;
  }
  Function _exceptionHandler = _defaultExceptionHandler;

  /// The request being processed by this [ResourceController].
  ///
  /// It is this [ResourceController]'s responsibility to return a [Response] object for this request.
  ResourceRequest resourceRequest;

  /// Parameters parsed from the URI of the request, if any exist.
  Map<String, String> get pathParameters => resourceRequest.pathParameters;

  /// Types of content this [ResourceController] will accept.
  ///
  /// By default, a resource controller will accept 'application/json' requests.
  /// If a request is sent to an instance of [ResourceController] and has an HTTP request body,
  /// but the Content-Type of the request isn't within this list, the [ResourceController]
  /// will automatically respond with an Unsupported Media Type response.
  List<ContentType> acceptedContentTypes = [ContentType.JSON];

  /// The content type of responses from this [ResourceController].
  ///
  /// Defaults to "application/json". This type will automatically be written to this response's
  /// HTTP header.
  ContentType responseContentType = ContentType.JSON;

  /// Encodes the HTTP response body object that is part of the [Response] returned from this request handler methods.
  ///
  /// By default, this encoder will convert the body object as JSON.
  dynamic responseBodyEncoder = (body) => JSON.encode(body);

  /// The HTTP request body object, after being decoded.
  ///
  /// This object will be decoded according to the request's content type. If there was no body, this value will be null.
  /// If this resource controller does not support the content type of the body, the controller will automatically
  /// respond with a Unsupported Media Type HTTP response.
  dynamic requestBody;

  Symbol _routeMethodSymbolForRequest(ResourceRequest req) {
    var symbol = null;

    var decls = reflect(this).type.declarations;
    for (var key in decls.keys) {
      var decl = decls[key];
      if (decl is MethodMirror) {
        var routeAttrs = decl.metadata.firstWhere(
                (attr) => attr.reflectee is Route, orElse: () => null);
        if (routeAttrs != null) {
          var params = (decl as MethodMirror).parameters
          .map((pm) => MirrorSystem.getName(pm.simpleName))
          .toList();
          Route r = new Route.fromRoute(routeAttrs.reflectee, params);

          if (r.matchesRequest(req)) {
            symbol = key;
            break;
          }
        }
      }
    }

    if (symbol == null) {
      throw new _InternalControllerException(
          "No handler for request method and parameters available.", HttpStatus.NOT_FOUND);
    }

    return symbol;
  }

  dynamic _readRequestBodyForRequest(ResourceRequest req) async
  {
    if (resourceRequest.request.contentLength > 0) {
      var incomingContentType = resourceRequest.request.headers.contentType;
      var matchingContentType = acceptedContentTypes.firstWhere((ct) {
        return ct.primaryType == incomingContentType.primaryType &&
        ct.subType == incomingContentType.subType;
      }, orElse: () => null);

      if (matchingContentType != null) {
        return (await HttpBodyHandler
        .processRequest(resourceRequest.request)).body;
      } else {
        throw new _InternalControllerException("Unsupported Content-Type", HttpStatus.UNSUPPORTED_MEDIA_TYPE);
      }
    }

    return null;
  }

  List<dynamic> _parametersForRequest(ResourceRequest req, Symbol handlerMethodSymbol) {
    var handlerMirror =
    reflect(this).type.declarations[handlerMethodSymbol] as MethodMirror;

    return handlerMirror.parameters
    .map((methodParameter) {
      var value = this.resourceRequest.pathParameters[MirrorSystem.getName(methodParameter.simpleName)];
      var parameterType = methodParameter.type;

      return value;
    }).toList();
  }

  Future process() async {
    try {
      var methodSymbol = _routeMethodSymbolForRequest(resourceRequest);
      var handlerParameters = _parametersForRequest(resourceRequest, methodSymbol);
      requestBody = await _readRequestBodyForRequest(resourceRequest);

      Future<Response> eventualResponse =
      reflect(this).invoke(methodSymbol, handlerParameters).reflectee;

      var response = await eventualResponse;

      response.body = responseBodyEncoder(response.body);
      response.headers[HttpHeaders.CONTENT_TYPE] = responseContentType.toString();
      response.respondToRequest(resourceRequest);
    } on _InternalControllerException catch (e) {
      resourceRequest.response.statusCode = e.statusCode;

      if (e.additionalHeaders != null) {
        e.additionalHeaders.forEach((name, values) {
          resourceRequest.response.headers.add(name, values);
        });
      }

      if (e.responseMessage != null) {
        resourceRequest.response.writeln(e.responseMessage);
      }

      resourceRequest.response.close();
    } catch (e, stacktrace) {
      _exceptionHandler(this.resourceRequest, e, stacktrace);
    }
  }

  static _defaultExceptionHandler(ResourceRequest resourceRequest, dynamic exceptionOrError, StackTrace stacktrace) {
    print(
        "Path: ${resourceRequest.request.uri}\nError: $exceptionOrError\n $stacktrace");

    resourceRequest.response.statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
    resourceRequest.response.close();
  }
}

class _InternalControllerException {
  final String message;
  final int statusCode;
  final HttpHeaders additionalHeaders;
  final String responseMessage;

  _InternalControllerException(this.message, this.statusCode,
                               {HttpHeaders additionalHeaders: null,
                               String responseMessage: null}) : this.additionalHeaders = additionalHeaders,
  this.responseMessage = responseMessage;
}
