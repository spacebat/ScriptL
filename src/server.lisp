(in-package :scriptl)

(defvar *scriptl-port* 4010)
(defvar *scriptl-uds* ".scriptl-sock")

(defvar *header* nil
  "SCRIPTL:HEADER for the current command, or `NIL` if there is no
command.")

(defvar *script* nil
  "String indicating the script name for the current command, or `NIL`
if there is no command.")



(defmacro sending-errors (stream &body body)
  (with-gensyms (unhandled-error)
    (once-only (stream)
      `(catch ',unhandled-error
         (handler-bind
             ((error
                (lambda (c)
                  (send-packet ,stream ":error")
                  (send-packet ,stream (class-name (class-of c)))
                  (send-packet ,stream
                               (with-output-to-string (str)
                                 (format str "~A~%~%" c)
                                 (trivial-backtrace:print-backtrace-to-stream str)))
                  (throw ',unhandled-error nil))))
           ,@body)))))

(defun client-loop (stream)
  (unwind-protect
       (catch 'error-handled
         (sending-errors stream
           (let* ((*header* (decode-header stream))
                  (*default-pathname-defaults* (header-cwd *header*)))
             (handle-client-for (header-version *header*) stream))))
    (close stream)))

(defmacro with-open-socket ((var type) &body body)
  `(let ((,var (sockets:make-socket :connect :passive
                                    :address-family ,type
                                    :type :stream)))
     (unwind-protect
          (progn ,@body)
       (close ,var))))

(defun bind-sock (sock type)
  (ecase type
    (:internet
     (sockets:bind-address sock sockets:+loopback+
                           :port *scriptl-port*
                           :reuse-address t))
    (:local
     (let ((addr (namestring
                  (merge-pathnames *scriptl-uds*
                                   (user-homedir-pathname))))
           (umask (osicat-posix:umask #o077)))
       (ignore-errors
        (osicat-posix:unlink addr))
       (sockets:bind-address sock (sockets:make-address addr))
       (osicat-posix:umask umask)))))

(defun server-loop (type)
  (with-open-socket (server type)
    (bind-sock server type)
    (sockets:listen-on server :backlog 5)
    (loop as socket = (iolib.sockets:accept-connection server :wait t)
          do (handler-case
                 (client-loop socket)
               (iolib.streams:hangup (c) (declare (ignore c)))))))

(defun start (&optional (type :local))
  (bt:make-thread (lambda () (server-loop type)) :name "ScriptL Server"))
