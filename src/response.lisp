(uiop:define-package #:reblocks/response
  (:use #:cl)
  (:import-from #:log)
  (:import-from #:parenscript)
  (:import-from #:reblocks/request
                #:get-uri
                #:ajax-request-p
                #:get-header)
  (:import-from #:reblocks/js/base
                #:with-javascript-to-string
                #:with-javascript)
  (:import-from #:reblocks/commands
                #:add-command)
  (:import-from #:quri)
  (:import-from #:alexandria
                #:appendf
                #:proper-list
                #:removef
                #:assoc-value)
  (:import-from #:serapeum
                #:->
                #:soft-list-of
                #:defvar-unbound)
  (:import-from #:cl-cookie
                #:cookie)
  (:import-from #:lack/response
                #:response-headers)
  (:import-from #:reblocks/page
                #:in-page-context-p
                #:current-page
                #:on-page-redirect)
  (:import-from #:reblocks/widget
                #:create-widget-from
                #:widget)
  (:import-from #:reblocks/widgets/string-widget
                #:make-string-widget)
  (:import-from #:reblocks/app
                #:app)
  (:import-from #:reblocks/variables
                #:*current-app*)
  (:export #:immediate-response
           #:make-response
           #:add-header
           #:send-script
           #:make-uri
           #:redirect
           #:get-response
           #:get-content
           #:get-code
           #:get-headers
           #:get-custom-headers
           #:get-content-type
           #:add-retpath-to
           #:set-cookie
           #:cookies-to-set
           #:status-code
           #:not-found-error
           #:not-found-error-widget
           #:not-found-error-app))
(in-package #:reblocks/response)


(defvar-unbound *response*
  "Current response object. It's status code and headers can be changed when processing a request.")


(defun get-default-content-type-for-response ()
  (if (ajax-request-p)
      "application/json"
      "text/html"))


(defun get-headers (&optional (response *response*))
  (check-type response lack/response:response)
  (lack/response:response-headers response))


(defun get-custom-headers (&optional (response *response*))
  "Function GET-CUSTOM-HEADERS is deprecated. Use GET-HEADERS instead."
  (check-type response lack/response:response)
  ;; TODO: remove this function after "2023-05-01"
  (log:warn "Function GET-CUSTOM-HEADERS is deprecated. Use GET-HEADERS instead.")
  (lack/response:response-headers response))


(defun get-code (&optional (response *response*))
  "Function GET-CODE is deprecated. Use STATUS-CODE instead."
  ;; TODO: remove this function after "2023-05-01"
  (log:warn "Function GET-CODE is deprecated. Use STATUS-CODE instead.")
  (lack/response:response-status response))


(defun status-code (&optional (response *response*))
  "Returns a status code to be returned in response to the current request.

   You can use SETF to change the status code:

   ```lisp
   (setf (reblocks/response:status-code)
         404)
   ```"
  (lack/response:response-status response))


(defun (setf status-code) (value &optional (response *response*))
  (setf (lack/response:response-status response)
        value))


(defun get-content (&optional (response *response*))
  (lack/response:response-body response))


(defun get-content-type (&optional (response *response*))
  (getf (get-headers response)
        :content-type))


(defgeneric get-response (obj)
  (:documentation "Extracts response from the object. Usually, obj will be an [IMMEDIATE-RESPONSE][condition] condition."))


(define-condition immediate-response ()
  ((response :type lack/response:response
             :initarg :response
             :reader get-response)))


(define-condition redirect (immediate-response)
  ())


(define-condition not-found-error (error)
  ((app :initarg :app
        :type (or null app)
        :reader not-found-error-app)
   (widget :initarg :widget
           :type widget
           :reader not-found-error-widget)))


(-> not-found-error ((or widget string))
    (values &optional))

(defun not-found-error (widget-or-string)
  "Signals an error about not found page or object.

   As the first argument you should pass a widget which will be shown
   as the error page's content. Also you migth pass a string, in this
   case content widget will be created automatically."
  (error 'not-found-error
         :app (when (boundp '*current-app*)
                *current-app*)
         :widget (etypecase widget-or-string
                   (widget widget-or-string)
                   (string (make-string-widget widget-or-string)))))


(defun make-response (content &key
                                (code 200)
                                (content-type (get-default-content-type-for-response))
                                (headers (get-headers)))
  (let ((headers (list* :content-type content-type
                        headers)))
    (lack/response:make-response code headers content)))


(defun add-header (name value)
  "Use this function to add a HTTP header:

   ```lisp
   (add-header :x-request-id \"100500\")
   ```"

  (check-type name symbol)
  (check-type value string)
  
  (unless (boundp '*response*)
    (error "Call ADD-HEADER function inside WITH-RESPONSE macro."))

  (setf (getf (response-headers *response*)
              name)
        value)
  (values))


(defun set-cookie (cookie &key (response *response*))
  "Use this function to add Set-Cookie header:

   ```lisp
   (set-cookie (list :name \"user_id\" :value \"bob\" :samesite :lax))
   ```

   Cookie might include these properties:

   - domain
   - path
   - expires
   - secure
   - httponly
   - samesite
"

  (check-type cookie proper-list)
  
  (unless (boundp '*response*)
    (error "Call SET-COOKIE function inside WITH-RESPONSE macro."))

  (appendf (lack/response:response-set-cookies response)
           (list (getf cookie :name)
                 cookie))
  
  (values))


(defun cookies-to-set (&optional (response *response*))
  "Returns a list with a map cookie-name -> cookie:cookie object.
   Odd items in this list are cookie names and even are lists with
   cookie parameters."
  (lack/response:response-set-cookies response))


(defun make-uri (new-path &key base-uri)
  "Makes a new URL, based on the current request's URL.

   Argument NEW-PATH can be absolute, like /logout or relative,
   like ./stories.

   Also, it can contain a query params like /login?code=100500

   By default, function takes a base-uri from the current request,
   bun in case if you want to call the function in a context where
   request is not available, you can pass BASE-URI argument explicitly."
  (let* ((base-uri (or base-uri
                       (get-uri)))
         (parsed-base (quri:uri base-uri))
         (parsed-new-path (quri:uri new-path))
         (new-url (quri:merge-uris parsed-new-path
                                   parsed-base)))
    (quri:render-uri new-url)))


(defun add-retpath-to (uri &key (retpath (reblocks/request:get-uri)))
  "Adds a \"retpath\" GET parameter to the giving URL.

   Keeps all other parameters and overwrites \"retpath\" parameter if it is
   already exists in the URL.

   By default, retpath is the current page, rendered by the reblocks.
   This is very useful to redirect user to login page and return him to the
   same page where he has been before."
  (let* ((parsed-base (quri:uri uri))
         (query (quri:uri-query parsed-base))
         (parsed-query (when query
                         (quri:url-decode-params query)))
         (_ (setf (assoc-value parsed-query
                                          "retpath"
                                          :test 'string-equal)
                  retpath))
         (new-query (quri:url-encode-params parsed-query))
         (parsed-new-path (quri:uri (concatenate 'string "?"
                                                 new-query)))
         (new-url (quri:merge-uris parsed-new-path
                                   parsed-base)))
    (declare (ignorable _))
    (quri:render-uri new-url)))


(defun immediate-response (content &key
                                     (condition-class 'immediate-response) 
                                     (code 200)
                                     content-type
                                     headers 
                                     cookies-to-set)
  "Aborts request processing by signaling an [IMMEDIATE-RESPONSE][condition]
   and returns a given value as response.

   HTTP code and headers are taken from CODE and CONTENT-TYPE.

   By default, headers and cookies are taken from the current request, but
   additional headers and cookies may be provides in appropriate arguments.
"

  ;; This abort could be a normal, like 302 redirect,
  ;; that is why we are just informing here
  (log:info "Aborting request processing"
            code
            content-type
            headers)

  (let* ((headers (append headers
                          (get-headers *response*)))
         (content-type (or content-type
                           (getf (get-headers *response*) :content-type)))
         (cookies-to-set (loop with result = (copy-alist (cookies-to-set *response*))
                               for (cookie-name cookie) in cookies-to-set
                               if (null cookie)
                                 do (removef result cookie-name
                                             :key #'car
                                             :test #'string-equal)
                               else
                                 do (setf (assoc-value result cookie-name)
                                          cookie)
                               finally (return result)))
         (new-response
           (make-response content
                          :code code
                          :content-type content-type
                          :headers headers)))
    (setf (lack/response:response-set-cookies new-response)
          cookies-to-set)
    (error condition-class :response new-response)))


(defun send-script (script &optional (place :after-load))
  "Send JavaScript to the browser. The way of sending depends
  on whether the current request is via AJAX or not.

  Script may be either a string or a list; if it is a list
  it will be compiled through Parenscript first."
  (declare (ignorable place))
  (let ((script (etypecase script
                  (string script)
                  (list (parenscript:ps* script)))))
    (if (ajax-request-p)
        (let ((code (if (equalp (get-header "X-Reblocks-Client")
                                "JQuery")
                        script
                        (with-javascript-to-string script))))
          (add-command :execute-code
                       :code code))
        (with-javascript
          script))))


(defun redirect (uri)
  "Redirects the client to a new URI."
  
  (when (in-page-context-p)
    (on-page-redirect (current-page) uri))
  
  (if (ajax-request-p)
      (add-command :redirect
                   :to uri)
      (immediate-response ""
                          :condition-class 'redirect
                          :headers (list :location uri)
                          :code 302)))


(defun call-with-response (thunk)
  (let* ((headers (list :content-type (get-default-content-type-for-response)
                        ;; We don't want content of Reblocks apps was cached
                        ;; by the browser, because widgets state can be changed
                        ;; in response to the actions and "Back" button might
                        ;; show the old state of the page in case of caching.
                        :cache-control "no-cache, no-store, must-revalidate"))
         (*response* (lack/response:make-response 200 headers ""))
         (started-at (get-internal-real-time))
         (result (funcall thunk))
         (ended-at (get-internal-real-time))
         (duration (float (/ (- ended-at started-at)
                             internal-time-units-per-second))))
    
    ;; Timing header according to
    ;; https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Server-Timing
    (add-header :server-timing
                (format nil "render;dur=~A" duration))

    (let ((prepared-result
            (cond
              (result
               (typecase result
                 (list
                  result)
                 (lack/response:response
                  result)
                 (function
                  result)
                 (pathname
                  (lack/response:make-response 200 nil result))
                 (string
                  (setf (lack/response:response-body *response*)
                        result)
                  *response*)
                 (t
                  (error "Unknown type of result: ~S"
                         (type-of result)))))
              (t
               *response*))))
      (typecase prepared-result
        (lack/response:response
         (lack/response:finalize-response prepared-result))
        (t
         prepared-result)))))


(defmacro with-response (() &body body)
  `(flet ((with-response-thunk ()
           ,@body))
     (call-with-response #'with-response-thunk)))
