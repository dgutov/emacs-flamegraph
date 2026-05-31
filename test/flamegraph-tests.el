;;; flamegraph-tests.el --- Tests for flamegraph.el  -*- lexical-binding: t; -*-

(require 'ert)
(require 'flamegraph)

(defun flamegraph-tests--calltree ()
  (let* ((root (profiler-make-calltree))
         (a (profiler-make-calltree :entry "a" :count 10 :parent root))
         (b (profiler-make-calltree :entry "b" :count 4 :parent a))
         (c (profiler-make-calltree :entry "c" :count 5 :parent root)))
    (setf (profiler-calltree-children root) (list a c)
          (profiler-calltree-children a) (list b))
    root))

(defmacro flamegraph-tests--with-svg-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(let ((flamegraph-renderer 'svg)
         (flamegraph-width 100)
         (flamegraph-svg-hover-delay 0))
     (cl-letf (((symbol-function 'display-graphic-p)
                (lambda (&optional _frame) t))
               ((symbol-function 'frame-char-width)
                (lambda (&optional _frame) 1))
               ((symbol-function 'create-image)
                (lambda (data type data-p &rest props)
                  (append (list 'image :type type
                                :data-p data-p :data data)
                          props))))
       (with-temp-buffer
         (flamegraph-mode)
         (setq flamegraph--top (flamegraph-tests--calltree)
               flamegraph--grand-total 15
               flamegraph--unit "samples"
               flamegraph--title "test")
         ,@body))))

(defun flamegraph-tests--frame-names ()
  (mapcar (lambda (hit)
            (flamegraph--entry-name
             (profiler-calltree-entry
              (flamegraph-frame-node (nth 4 hit)))))
          (append flamegraph--svg-hitboxes nil)))

(ert-deftest flamegraph-svg-render-builds-rows-hitboxes-and-maps ()
  (flamegraph-tests--with-svg-buffer
    (flamegraph--draw)
    (should (= 2 (length flamegraph--frame-positions)))
    (should (= 3 (length flamegraph--svg-hitboxes)))
    (should (equal '("a" "c" "b") (flamegraph-tests--frame-names)))
    (let* ((row0 (aref (plist-get flamegraph--svg-state :rows) 0))
           (row1 (aref (plist-get flamegraph--svg-state :rows) 1))
           (display0 (get-text-property (aref row0 3) 'display))
           (display1 (get-text-property (aref row1 3) 'display)))
      (should (string-match-p "<svg width=\"100\""
                              (plist-get (cdr display0) :data)))
      (should (string-match-p "<text [^>]*>a</text>"
                              (plist-get (cdr display0) :data)))
      (should (string-match-p "<text [^>]*>b</text>"
                              (plist-get (cdr display1) :data)))
      (should (= 2 (length (plist-get (cdr display0) :map))))
      (should (= 1 (length (plist-get (cdr display1) :map))))
      (dolist (area (plist-get (cdr display0) :map))
        (should (functionp (plist-get (nth 2 area) 'help-echo)))))))

(ert-deftest flamegraph-svg-navigation-survives-redraw ()
  (flamegraph-tests--with-svg-buffer
    (flamegraph--draw)
    (should (equal "a"
                   (flamegraph--entry-name
                    (profiler-calltree-entry
                     (flamegraph-frame-node
                      (flamegraph--svg-current-frame))))))
    (let ((inhibit-message t))
      (flamegraph-next))
    (should (equal "c"
                   (flamegraph--entry-name
                    (profiler-calltree-entry
                     (flamegraph-frame-node
                      (flamegraph--svg-current-frame))))))
    (flamegraph--draw)
    (should (equal "c"
                   (flamegraph--entry-name
                    (profiler-calltree-entry
                     (flamegraph-frame-node
                      (flamegraph--svg-current-frame))))))))

(ert-deftest flamegraph-svg-hover-help-echo-redraws-row ()
  (flamegraph-tests--with-svg-buffer
    (flamegraph--draw)
    (let* ((display (get-text-property (point-min) 'display))
           (map (plist-get (cdr display) :map))
           (help (plist-get (nth 2 (car map)) 'help-echo)))
      (should (functionp help))
      (funcall help nil nil nil)
      (accept-process-output nil 0.01)
      (let ((display (get-text-property (point-min) 'display)))
        (should (string-match-p "stroke=\"#1f6feb\""
                                (plist-get (cdr display) :data)))))))

(provide 'flamegraph-tests)

;;; flamegraph-tests.el ends here
