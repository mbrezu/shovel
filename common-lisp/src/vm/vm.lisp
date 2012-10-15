
(in-package :shovel-vm)

(defvar *error-raiser*)

(defvar *version* 1)

(defstruct vm
  bytecode
  program-counter
  current-environment
  stack
  user-primitives
  (last-start-pos nil)
  (last-end-pos nil)
  (sources nil)
  (should-take-a-nap nil)
  (user-primitive-error nil)
  (programming-error nil))

(defstruct return-address
  program-counter
  environment)

(defstruct named-block name end-address environment)

(defstruct callable
  (prim0 nil)
  (prim nil)
  (num-args nil)
  (program-counter nil)
  (environment nil))

(defstruct env-frame introduced-at-program-counter vars)

(defmacro def-prim0 (op lisp-op &optional (arity 2))
  `(list ,(format nil "~a" op) ',lisp-op ,arity))

(defparameter *primitives*
  (let ((prim0-alist
         (list
          ;; Arithmetic operators:
          (def-prim0 + shovel-vm-prim0:add)
          (def-prim0 - shovel-vm-prim0:subtract)
          (def-prim0 "unary-minus" shovel-vm-prim0:unary-minus 1)
          (def-prim0 * shovel-vm-prim0:multiply)
          (def-prim0 / shovel-vm-prim0:divide)
          (def-prim0 << shovel-vm-prim0:shift-left)
          (def-prim0 >> shovel-vm-prim0:shift-right)
          (def-prim0 % shovel-vm-prim0:modulo)
          (def-prim0 "pow" shovel-vm-prim0:pow)
          (def-prim0 "floor" floor 1)

          ;; Relational operators:
          (def-prim0 < shovel-vm-prim0:less-than)
          (def-prim0 <= shovel-vm-prim0:less-than-or-equal)
          (def-prim0 > shovel-vm-prim0:greater-than)
          (def-prim0 >= shovel-vm-prim0:greater-than-or-equal)
          (def-prim0 == shovel-vm-prim0:are-equal)
          (def-prim0 != shovel-vm-prim0:are-not-equal)

          ;; Logic operators:
          (def-prim0 && shovel-vm-prim0:logical-and)
          (def-prim0 "||" shovel-vm-prim0:logical-or)
          (def-prim0 ! shovel-vm-prim0:logical-not 1)

          ;; Bitwise operators:
          (def-prim0 "&" shovel-vm-prim0:bitwise-and)
          (def-prim0 "|" shovel-vm-prim0:bitwise-or)
          (def-prim0 "^" shovel-vm-prim0:bitwise-xor)

          ;; Hash constructor:
          (def-prim0 "hash" shovel-vm-prim0:hash-constructor nil)

          ;; Hash table has key?
          (def-prim0 "hasKey" shovel-vm-prim0:has-key 2)

          ;; Keys for hash table
          (def-prim0 "keys" shovel-vm-prim0:get-hash-table-keys 1)

          ;; Array constructors:
          (def-prim0 "array" shovel-vm-prim0:array-constructor nil)
          (def-prim0 "arrayN" shovel-vm-prim0:array-constructor-n 1)

          ;; Array push and pop:
          (def-prim0 "push" shovel-vm-prim0:array-push)
          (def-prim0 "pop" shovel-vm-prim0:array-pop 1)

          ;; Array and hash set and get:
          (def-prim0 "svm_gref" shovel-vm-prim0:array-or-hash-get)
          (def-prim0 "svm_gref_dot" shovel-vm-prim0:hash-get-dot)
          (def-prim0 "svm_set_indexed" shovel-vm-prim0:array-or-hash-set 3)

          ;; String or array length:
          (def-prim0 "length" shovel-vm-prim0:get-length 1)

          ;; String or array slice:
          (def-prim0 "slice" shovel-vm-prim0:get-slice 3)

          ;; String 'upper' and 'lower':
          (def-prim0 "upper" shovel-vm-prim0:string-upper 1)
          (def-prim0 "lower" shovel-vm-prim0:string-lower 1)

          ;; Current date/time:
          (def-prim0 "utcSecondsSinceUnixEpoch"
              shovel-vm-prim0:utc-seconds-since-unix-epoch 0)

          ;; Date/time construction/deconstruction:
          (def-prim0 "decodeTime" shovel-vm-prim0:decode-time 1)
          (def-prim0 "encodeTime" shovel-vm-prim0:encode-time 1)

          ;; Object types:
          (def-prim0 "isString" shovel-vm-prim0:shovel-is-string 1)
          (def-prim0 "isHash" shovel-vm-prim0:shovel-is-hash 1)
          (def-prim0 "isBool" shovel-vm-prim0:shovel-is-bool 1)
          (def-prim0 "isArray" shovel-vm-prim0:shovel-is-array 1)
          (def-prim0 "isNumber" shovel-vm-prim0:shovel-is-number 1)
          (def-prim0 "isCallable" shovel-vm-prim0:shovel-is-callable 1)

          ;; Stringification:
          (def-prim0 "string" shovel-vm-prim0:shovel-string 1)
          (def-prim0 "stringRepresentation"
              shovel-vm-prim0:shovel-string-representation 1)

          ;; Parsing numbers:
          (def-prim0 "parseInt" shovel-vm-prim0:parse-int 1)
          (def-prim0 "parseFloat" shovel-vm-prim0:parse-float 1)

          ;; Exception throwing:
          (def-prim0 "panic" shovel-vm-prim0:panic 1)
          )))
    (alexandria:alist-hash-table prim0-alist :test #'equal)))

(defun write-environment (env vm stream)
  (when env
    (let ((frame (car env)))
      (alexandria:when-let (pc (env-frame-introduced-at-program-counter frame))
        (let ((instruction (aref (vm-bytecode vm) pc)))
          (format stream "Frame starts at:~%")
          (print-line-for vm stream
                          (env-frame-introduced-at-program-counter frame)
                          (instruction-start-pos instruction)
                          (instruction-end-pos instruction))))
      (format stream "Frame variables are:~%")
      (loop
         for i from 0 to (1- (length (env-frame-vars frame)))
         do (let ((var (elt (env-frame-vars frame) i)))
              (format stream "~a = ~a~%"
                      (first var)
                      (shovel-vm-prim0:shovel-string-representation
                       (second var)))))
      (terpri stream))
    (write-environment (cdr env) vm stream)))

(defun find-file-name (vm program-counter)
  (let (result)
    (loop
       for pc from program-counter downto 0
       when (eq :file-name (instruction-opcode (aref (vm-bytecode vm) pc)))
       do
         (setf result (instruction-arguments (aref (vm-bytecode vm) pc)))
         (loop-finish))
    result))

(defun print-line-for (vm stream
                       program-counter
                       character-start-pos character-end-pos)
  (let (found-location)
    (when (and character-start-pos character-end-pos)
      (alexandria:when-let (sources (vm-sources vm))
        (alexandria:when-let*
            ((file-name (find-file-name vm program-counter))
             (shript-file (find-source sources file-name))
             (content (shript-file-contents shript-file))
             (start-pos (find-position file-name
                                       content
                                       character-start-pos))
             (end-pos (find-position file-name
                                     content
                                     character-end-pos)))
          (dolist (line (extract-relevant-source sources
                                                 start-pos end-pos))
            (write-string line stream)
            (terpri stream))
          (setf found-location t))))
    (unless found-location
      (format stream "... unknown source location, program counter ~d ..."
              program-counter)
      (terpri stream))))

(defun wake-up-vm (vm)
  (setf (vm-should-take-a-nap vm) nil))

(defun write-stack-trace (vm stream &optional stack-dump)
  (labels ((iter (stack)
             (when stack
               (if (return-address-p (car stack))
                   (let* ((pc (return-address-program-counter (car stack)))
                          (call-site (elt (vm-bytecode vm) (1- pc))))
                     (print-line-for vm stream pc
                                     (instruction-start-pos call-site)
                                     (instruction-end-pos call-site)))
                   (if stack-dump
                       (format stream "~a~%"
                               (shovel-vm-prim0:shovel-string-representation
                                (car stack)))))
               (iter (cdr stack)))))
    (unless stack-dump
      (print-line-for vm stream
                      (vm-program-counter vm)
                      (vm-last-start-pos vm)
                      (vm-last-end-pos vm)))
    (iter (vm-stack vm))))

(defun raise-shovel-error (vm message)
  (setf message
        (with-output-to-string (str)
          (write-string message str) (terpri str) (terpri str)
          (write-string "Current stack trace:" str) (terpri str)
          (write-stack-trace vm str)
          (terpri str)
          (write-string "Current environment:" str) (terpri str) (terpri str)
          (write-environment (vm-current-environment vm) vm str)))
  (let (pos file-name line column)
    (setf file-name (find-file-name vm (vm-program-counter vm)))
    (when (and file-name (vm-sources vm))
      (alexandria:when-let* ((shript-file (find-source (vm-sources vm) file-name))
                             (content (shript-file-contents shript-file)))
        (setf pos (find-position file-name content (vm-last-start-pos vm)))
        (when pos
          (setf line (pos-line pos))
          (setf column (pos-column pos)))))
    (error
     (alexandria:if-let (pos (vm-last-start-pos vm))
       (make-condition 'shovel-error
                       :message message
                       :file file-name
                       :line line
                       :column column)
       (make-condition 'shovel-error :message message)))))

(defun find-required-primitive (vm name)
  (let ((primitive (gethash name *primitives*)))
    (unless primitive
      (raise-shovel-error vm (format nil "Unknown prim0 '~a'." name)))
    primitive))

(defun run-vm (bytecode &key sources user-primitives state vm)
  (unless vm
    (setf vm (make-vm :bytecode bytecode
                      :program-counter 0
                      :current-environment nil
                      :stack nil
                      :user-primitives (make-hash-table :test #'equal)
                      :sources sources)))
  (when state
    (deserialize-vm-state vm state))
  (dolist (user-primitive user-primitives)
    (setf (gethash (first user-primitive) (vm-user-primitives vm))
          (rest user-primitive)))
  (handler-bind ((error (lambda (condition)
                          (setf (vm-programming-error vm) condition))))
    (loop while (step-vm vm))
    (values (first (vm-stack vm)) vm)))

(defun get-vm-stack (vm)
  (with-output-to-string (str)
    (write-stack-trace vm str)))

(defun get-vm-environment (vm)
  (with-output-to-string (str)
    (write-environment (vm-current-environment vm) vm str)))

(defun vm-not-finished (vm)
  (and
   (< (vm-program-counter vm) (length (vm-bytecode vm)))
   (not (vm-should-take-a-nap vm))))

(defun check-bool (vm)
  (unless (shovel-vm-prim0:is-bool (first (vm-stack vm)))
    (raise-shovel-error vm "Argument must be a boolean.")))

(defun check-vm-without-error (vm)
  (alexandria:when-let (err (vm-user-primitive-error vm))
    (error err))
  (alexandria:when-let (err (vm-programming-error vm))
    (error err)))

(defun step-vm (vm)
  (check-vm-without-error vm)
  (when (vm-not-finished vm)
    (let* ((shovel-vm:*error-raiser* (lambda (message)
                                       (raise-shovel-error vm message)))
           (instruction (elt (vm-bytecode vm) (vm-program-counter vm)))
           (opcode (instruction-opcode instruction))
           (args (instruction-arguments instruction)))
      (alexandria:when-let ((start-pos (instruction-start-pos instruction))
                            (end-pos (instruction-end-pos instruction)))
        (setf (vm-last-start-pos vm) start-pos
              (vm-last-end-pos vm) end-pos))
      (case opcode
        (:jump (setf (vm-program-counter vm) args))
        (:const
         (push args (vm-stack vm))
         (incf (vm-program-counter vm)))
        (:prim0
         (push (make-callable :prim0 args) (vm-stack vm))
         (incf (vm-program-counter vm)))
        (:prim
         (push (make-callable :prim args) (vm-stack vm))
         (incf (vm-program-counter vm)))
        (:call (handle-call vm args t))
        (:callj (handle-call vm args nil))
        (:fjump
         (check-bool vm)
         (jump-if (shovel-vm-prim0:logical-not (pop (vm-stack vm))) vm args))
        (:lset
         (set-in-environment (vm-current-environment vm)
                             (first args) (second args)
                             (first (vm-stack vm)))
         (incf (vm-program-counter vm)))
        (:pop
         (pop (vm-stack vm))
         (incf (vm-program-counter vm)))
        (:lget
         (push (get-from-environment (vm-current-environment vm)
                                     (first args) (second args))
               (vm-stack vm))
         (incf (vm-program-counter vm)))
        (:fn
         (push (make-callable :program-counter (first args)
                              :environment (vm-current-environment vm)
                              :num-args (second args))
               (vm-stack vm))
         (incf (vm-program-counter vm)))
        (:new-frame
         (let ((new-frame (make-env-frame
                           :introduced-at-program-counter (vm-program-counter vm)
                           :vars (make-array (length args)))))
           (loop
              for i = 0 then (1+ i)
              for var in args
              do (setf (aref (env-frame-vars new-frame) i) (list var :null)))
           (push new-frame (vm-current-environment vm)))
         (incf (vm-program-counter vm)))
        (:drop-frame
         (pop (vm-current-environment vm))
         (incf (vm-program-counter vm)))
        (:args (handle-args vm args))
        (:return
          (let ((other-stack (cddr (vm-stack vm)))
                (result (first (vm-stack vm)))
                (retaddr (second (vm-stack vm))))
            (apply-return-address vm retaddr)
            (setf (vm-stack vm)
                  (cons result other-stack))))
        (:block
            (let ((name (pop (vm-stack vm))))
              (unless (stringp name)
                (raise-shovel-error vm "The name of a block must be a string."))
              (push (make-named-block :name name
                                      :end-address args
                                      :environment (vm-current-environment vm))
                    (vm-stack vm)))
          (incf (vm-program-counter vm)))
        (:pop-block
         (let ((return-value (first (vm-stack vm)))
               (named-block (second (vm-stack vm)))
               (rest-of-the-stack (cddr (vm-stack vm))))
           (unless (named-block-p named-block)
             (raise-shovel-error vm "Invalid context for POP_BLOCK."))
           (setf (vm-stack vm) (cons return-value rest-of-the-stack)))
         (incf (vm-program-counter vm)))
        (:block-return
         (let ((return-value (first (vm-stack vm)))
               (name (second (vm-stack vm))))
           (unless (stringp name)
             (raise-shovel-error vm "The name of a block must be a string."))
           (multiple-value-bind (named-block stack-below)
               (find-named-block vm (vm-stack vm) name)
             (setf (vm-stack vm) (list* return-value
                                        named-block
                                        stack-below))
             (setf (vm-current-environment vm)
                   (named-block-environment named-block))
             (setf (vm-program-counter vm)
                   (named-block-end-address named-block)))))
        (:context
         (let ((stack-trace (with-output-to-string (str)
                              (write-stack-trace vm str)))
               (current-environment (with-output-to-string (str)
                                      (write-environment (vm-current-environment vm)
                                                         vm str)))
               (context (make-hash-table :test #'equal)))
           (setf (gethash "stack" context) stack-trace)
           (setf (gethash "environment" context) current-environment)
           (push context (vm-stack vm))
           (incf (vm-program-counter vm))))
        (:tjump
         (check-bool vm)
         (jump-if (pop (vm-stack vm)) vm args))
        ((:file-name :vm-version :vm-sources-md5 :vm-bytecode-md5)
                                        ; These are just informational
                                        ; instructions, skip them.
         (incf (vm-program-counter vm)))
        (t (error "Shovel internal WTF: unknown instruction '~a'." opcode)))))
  (vm-not-finished vm))

(defun find-named-block (vm stack block-name)
  (cond ((null stack)
         (raise-shovel-error vm (format nil "Cannot find block '~a'." block-name)))
        ((and (named-block-p (first stack))
              (string= block-name (named-block-name (first stack))))
         (values (first stack) (rest stack)))
        (t (find-named-block vm (rest stack) block-name))))

(defun find-user-primitive (vm primitive-name)
  (or (gethash primitive-name (vm-user-primitives vm))
      (raise-shovel-error vm
                          (format nil "Unknown user primitive '~a'."
                                  primitive-name))))

(defun jump-if (value vm jump-address)
  (if (shovel-vm-prim0:is-true value)
      (setf (vm-program-counter vm) jump-address)
      (incf (vm-program-counter vm))))

(defun apply-return-address (vm retaddr)
  (setf (vm-program-counter vm) (return-address-program-counter retaddr)
        (vm-current-environment vm) (return-address-environment retaddr)))

(defun handle-args (vm args)
  (let ((arg-values (subseq (vm-stack vm) 0 args)))
    (setf (vm-stack vm) (nthcdr args (vm-stack vm)))
    (setf arg-values (nreverse arg-values))
    (dotimes (i (length arg-values))
      (set-in-environment (vm-current-environment vm)
                          0 i
                          (nth i arg-values))))
  (incf (vm-program-counter vm)))

(defun handle-call (vm num-args save-return-address)
  (let ((callable (pop (vm-stack vm))))
    (unless (callable-p callable)
      (raise-shovel-error vm (format nil "Object [~a] is not callable."
                                     (shovel-vm-prim0:shovel-string-representation
                                      callable))))
    (if (or (callable-prim callable) (callable-prim0 callable))
        (call-primitive callable vm num-args save-return-address)
        (call-function callable vm num-args save-return-address))))

(defun arity-error (vm expected-arity actual-arity)
  (raise-shovel-error
   vm (format nil "Function of ~d arguments called with ~d arguments."
              expected-arity actual-arity)))

(defun call-function (callable vm num-args save-return-address)
  (when save-return-address
    (setf (vm-stack vm)
          (append
           (subseq (vm-stack vm) 0 num-args)
           (cons (make-return-address :program-counter (1+ (vm-program-counter vm))
                                      :environment (vm-current-environment vm))
                 (nthcdr num-args (vm-stack vm))))))
  (when (and (callable-num-args callable )
             (/= (callable-num-args callable) num-args))
    (arity-error vm (callable-num-args callable) num-args))
  (setf (vm-program-counter vm) (callable-program-counter callable)
        (vm-current-environment vm) (callable-environment callable)))

(defun is-shovel-type (data)
  (cond ((or (stringp data) (numberp data)
             (eq :true data) (eq :false data) (eq :null data)
             (callable-p data))
         t)
        ((vectorp data)
         (dotimes (i (length data))
           (unless (is-shovel-type (aref data i))
             (return-from is-shovel-type nil)))
         t)
        ((hash-table-p data)
         (maphash (lambda (key value)
                    (unless (and (stringp key) (is-shovel-type value))
                      (return-from is-shovel-type nil)))
                  data)
         t)))

(defun call-primitive (callable vm num-args save-return-address)
  (let* ((arg-values (subseq (vm-stack vm) 0 num-args))
         (primitive-record (or (alexandria:if-let (prim0 (callable-prim0 callable))
                                 (find-required-primitive vm prim0))
                               (alexandria:if-let (prim (callable-prim callable))
                                 (find-user-primitive vm prim))))
         (primitive (first primitive-record))
         (is-required-primitive (callable-prim0 callable))
         (primitive-arity (second primitive-record))
         (current-program-counter (vm-program-counter vm)))
    (when (and primitive-arity (/= primitive-arity num-args))
      (arity-error vm primitive-arity num-args))
    (multiple-value-bind(result what-next)
        (if is-required-primitive
            (apply primitive (reverse arg-values))
            (handler-case
                (apply primitive (reverse arg-values))
              (error (err)
                (setf (vm-user-primitive-error vm) err)
                (values :null :nap-and-retry-on-wake-up))))
      (unless is-required-primitive
        (unless (is-shovel-type result)
          (raise-shovel-error
           vm
           (format nil "User defined primitive returned invalid value (~a).

A 'valid value' (with Common Lisp as the host language) is:

 * :null, :true or :false;
 * a string;
 * a number;
 * an array of elements that are themselves valid values;
 * a hash with strings as keys and valid values.
"
                   result))))
      (let (should-finish-this-call)
        (cond ((or is-required-primitive
                   (null what-next)
                   (eq :continue what-next))
               (setf should-finish-this-call t))
              ((eq :nap what-next)
               (setf (vm-should-take-a-nap vm) t)
               (setf should-finish-this-call t))
              ((eq :nap-and-retry-on-wake-up what-next)
               (setf (vm-should-take-a-nap vm) t)
               (setf (vm-program-counter vm) current-program-counter)
               (push callable (vm-stack vm)))
              (t (raise-shovel-error
                  vm
                  "A user-defined primitive returned an unknown second value.")))
        (when should-finish-this-call
          (setf (vm-stack vm) (nthcdr num-args (vm-stack vm)))
          (if save-return-address
              (incf (vm-program-counter vm))
              (apply-return-address vm (pop (vm-stack vm))))
          (push result (vm-stack vm)))))))

(defun set-in-environment (environment frame-number var-index value)
  (setf (second (aref (env-frame-vars (nth frame-number environment))
                      var-index))
        value))

(defun get-from-environment (enviroment frame-number var-index)
  (second (aref (env-frame-vars (nth frame-number enviroment))
                var-index)))

(defstruct serializer-state (hash (make-hash-table)) (array nil))

(defmacro get-serialization-code (symbol)
  (case symbol
    (:host-null 1)
    (:true 2)
    (:false 3)
    (:guest-null 4)
    (:cons 5)
    (:array 6)
    (:hash 7)
    (:callable 8)
    (:return-address 9)
    (:env-frame 10)
    (:named-block 11)))

(defun serialize (object ss)
  (labels ((store-one (obj &key (store-as obj))
             (let ((new-index (length (serializer-state-array ss))))
               (setf (gethash store-as (serializer-state-hash ss)) new-index)
               (push obj (serializer-state-array ss))
               new-index))
           (make-array-1 (value)
             (make-array 1 :initial-element value)))
    (alexandria:if-let (object-index (gethash object (serializer-state-hash ss)))
      object-index
      (cond ((or (stringp object) (numberp object)) (store-one object))
            ((null object) (store-one (make-array-1
                                       (get-serialization-code :host-null))
                                      :store-as object))
            ((eq :true object) (store-one (make-array-1
                                           (get-serialization-code :true))
                                          :store-as object))
            ((eq :false object) (store-one (make-array-1
                                            (get-serialization-code :false))
                                           :store-as object))
            ((eq :null object) (store-one (make-array-1
                                           (get-serialization-code :guest-null))
                                          :store-as object))
            ((consp object)
             (let* ((result-array (make-array 3))
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array 0) (get-serialization-code :cons))
               (let* ((car-index (serialize (car object) ss))
                      (cdr-index (serialize (cdr object) ss)))
                 (setf (aref result-array 1) car-index)
                 (setf (aref result-array 2) cdr-index))
               result))
            ((vectorp object)
             (let* ((result-array (make-array (1+ (length object))))
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array 0) (get-serialization-code :array))
               (loop
                  for i from 0 to (1- (length object))
                  do (setf (aref result-array (1+ i))
                           (serialize (aref object i) ss)))
               result))
            ((hash-table-p object)
             (let* ((result-array (make-array (1+ (* 2 (hash-table-count object)))))
                    (i 0)
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array i) (get-serialization-code :hash))
               (incf i)
               (maphash (lambda (key value)
                          (setf (aref result-array i) (serialize key ss))
                          (incf i)
                          (setf (aref result-array i) (serialize value ss))
                          (incf i))
                        object)
               result))
            ((callable-p object)
             (let* ((result-array (make-array 6))
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array 0) (get-serialization-code :callable))
               (setf (aref result-array 1) (serialize (callable-prim0 object) ss))
               (setf (aref result-array 2) (serialize (callable-prim object) ss))
               (setf (aref result-array 3)
                     (serialize (callable-num-args object) ss))
               (setf (aref result-array 4)
                     (serialize (callable-program-counter object) ss))
               (setf (aref result-array 5)
                     (serialize (callable-environment object) ss))
               result))
            ((return-address-p object)
             (let* ((result-array (make-array 3))
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array 0) (get-serialization-code :return-address))
               (setf (aref result-array 1)
                     (serialize (return-address-program-counter object) ss))
               (setf (aref result-array 2)
                     (serialize (return-address-environment object) ss))
               result))
            ((env-frame-p object)
             (let* ((result-array (make-array 3))
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array 0) (get-serialization-code :env-frame))
               (setf (aref result-array 1)
                     (serialize (env-frame-introduced-at-program-counter object)
                                ss))
               (setf (aref result-array 2) (serialize (env-frame-vars object) ss))
               result))
            ((named-block-p object)
             (let* ((result-array (make-array 4))
                    (result (store-one result-array :store-as object)))
               (setf (aref result-array 0) (get-serialization-code :named-block))
               (setf (aref result-array 1)
                     (serialize (named-block-name object) ss))
               (setf (aref result-array 2)
                     (serialize (named-block-end-address object) ss))
               (setf (aref result-array 3)
                     (serialize (named-block-environment object) ss))
               result))
            (t (error "Internal error: Don't know how to serialize object!"))))))

(defstruct deserializer-state (array nil) (objects nil))

(defun deserialize (index ds)
  (let ((serialized-object (aref (deserializer-state-array ds) index))
        (deserialize-error
         "Internal error: Don't know how to deserialize object!"))
    (if (or (stringp serialized-object)
            (numberp serialized-object))
        serialized-object
        (symbol-macrolet ((object-ref (aref (deserializer-state-objects ds) index)))
          (alexandria:if-let (object object-ref)
            object
            (cond ((consp serialized-object)
                   (let ((result (cons nil nil)))
                     (setf object-ref result)
                     (setf (car result) (deserialize (car serialized-object) ds))
                     (setf (cdr result) (deserialize (cdr serialized-object) ds))
                     result))
                  ((vectorp serialized-object)
                   (if (= 0 (length serialized-object))
                       (error deserialize-error))
                   (let ((code (aref serialized-object 0)))
                     (cond
                       ((= code (get-serialization-code :host-null)) nil)
                       ((= code (get-serialization-code :guest-null)) :null)
                       ((= code (get-serialization-code :true)) :true)
                       ((= code (get-serialization-code :false)) :false)
                       ((= code (get-serialization-code :cons))
                        (let ((result (cons nil nil)))
                          (setf object-ref result)
                          (setf (car result)
                                (deserialize (aref serialized-object 1) ds))
                          (setf (cdr result)
                                (deserialize (aref serialized-object 2) ds))
                          result))
                       ((= code (get-serialization-code :array))
                        (let* ((n (1- (length serialized-object)))
                               (result (make-array n
                                                   :adjustable t
                                                   :fill-pointer n)))
                          (setf object-ref result)
                          (loop
                             for i from 0 to (1- (length result))
                             do (setf (aref result i)
                                      (deserialize (aref serialized-object (1+ i))
                                                   ds)))
                          result))
                       ((= code (get-serialization-code :hash))
                        (let ((result (make-hash-table :test #'equal)))
                          (setf object-ref result)
                          (loop
                             for i from 0 to (- (length serialized-object) 2) by 2
                             do (let ((key (deserialize
                                            (aref serialized-object (1+ i)) ds))
                                      (value (deserialize
                                              (aref serialized-object (+ 2 i)) ds)))
                                  (setf (gethash key result) value)))
                          result))
                       ((= code (get-serialization-code :callable))
                        (let ((result (make-callable)))
                          (setf object-ref result)
                          (setf (callable-prim0 result)
                                (deserialize (aref serialized-object 1) ds))
                          (setf (callable-prim result)
                                (deserialize (aref serialized-object 2) ds))
                          (setf (callable-num-args result)
                                (deserialize (aref serialized-object 3) ds))
                          (setf (callable-program-counter result)
                                (deserialize (aref serialized-object 4) ds))
                          (setf (callable-environment result)
                                (deserialize (aref serialized-object 5) ds))
                          result))
                       ((= code (get-serialization-code :return-address))
                        (let ((result (make-return-address)))
                          (setf object-ref result)
                          (setf (return-address-program-counter result)
                                (deserialize (aref serialized-object 1) ds))
                          (setf (return-address-environment result)
                                (deserialize (aref serialized-object 2) ds))
                          result))
                       ((= code (get-serialization-code :env-frame))
                        (let ((result (make-env-frame
                                       :introduced-at-program-counter nil
                                       :vars nil)))
                          (setf object-ref result)
                          (setf (env-frame-introduced-at-program-counter result)
                                (deserialize (aref serialized-object 1) ds))
                          (setf (env-frame-vars result)
                                (deserialize (aref serialized-object 2) ds))
                          result))
                       ((= code (get-serialization-code :named-block))
                        (let ((result (make-named-block
                                       :name nil
                                       :end-address nil
                                       :environment nil)))
                          (setf object-ref result)
                          (setf (named-block-name result)
                                (deserialize (aref serialized-object 1) ds))
                          (setf (named-block-end-address result)
                                (deserialize (aref serialized-object 2) ds))
                          (setf (named-block-environment result)
                                (deserialize (aref serialized-object 3) ds))
                          result))
                       (t (error deserialize-error)))))
                  (t
                   (error deserialize-error))))))))

(defun get-vm-arguments-for-opcode (vm opcode)
  (dotimes (i (length (vm-bytecode vm)))
    (let ((instruction (aref (vm-bytecode vm) i)))
      (when (eq opcode (instruction-opcode instruction))
        (alexandria:when-let (result (instruction-arguments instruction))
          (return-from get-vm-arguments-for-opcode result)))))
  (error "Shovel Internal WTF: VM without ~a." opcode))

(defun get-vm-version (vm)
  (get-vm-arguments-for-opcode vm :vm-version))

(defun get-vm-bytecode-md5 (vm)
  (let ((result (get-vm-arguments-for-opcode vm :vm-bytecode-md5)))
    (when (string= "?" result)
      (error "Shovel Internal WTF: VM without bytecode MD5 hash."))
    result))

(defun get-vm-sources-md5 (vm)
  (get-vm-arguments-for-opcode vm :vm-sources-md5))

(defun serialize-vm-state (vm)
  (check-vm-without-error vm)
  (let ((ss (make-serializer-state))
        stack current-environment program-counter)
    (setf stack (serialize (vm-stack vm) ss))
    (setf current-environment (serialize (vm-current-environment vm) ss))
    (setf program-counter (serialize (vm-program-counter vm) ss))
    (let ((serialized-state (list stack current-environment program-counter
                                  (nreverse (serializer-state-array ss))
                                  (get-vm-version vm)
                                  (get-vm-bytecode-md5 vm)
                                  (get-vm-sources-md5 vm))))
      (messagepack-encode-with-md5-checksum serialized-state))))

(defun deserialize-vm-state (vm state-bytes)
  (let* ((vm-state (check-md5-checksum-and-messagepack-decode state-bytes))
         (stack-index (aref vm-state 0))
         (current-environment-index (aref vm-state 1))
         (program-counter-index (aref vm-state 2))
         (array (aref vm-state 3))
         (vm-version (aref vm-state 4))
         (vm-bytecode-md5 (aref vm-state 5))
         (vm-sources-md5 (aref vm-state 6))
         (ds (make-deserializer-state :array array
                                      :objects (make-array (length array)
                                                           :initial-element nil))))
    (unless (= vm-version (get-vm-version vm))
      (error (make-condition
              'shovel-vm-match-error
              :message "VM version and serialized VM version do not match.")))
    (unless (string= vm-bytecode-md5 (get-vm-bytecode-md5 vm))
      (error (make-condition
              'shovel-vm-match-error
              :message
              "VM bytecode MD5 and serialized VM bytecode MD5 do not match.")))
    (unless (string= vm-sources-md5 (get-vm-sources-md5 vm))
      (error (make-condition
              'shovel-vm-match-error
              :message
              "VM sources MD5 and serialized VM sources MD5 do not match.")))
    (setf (vm-stack vm) (deserialize stack-index ds))
    (setf (vm-current-environment vm) (deserialize current-environment-index ds))
    (setf (vm-program-counter vm) (deserialize program-counter-index ds))))
