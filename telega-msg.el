;;; telega-msg.el --- Messages for telega  -*- lexical-binding:t -*-

;; Copyright (C) 2018 by Zajcev Evgeny.

;; Author: Zajcev Evgeny <zevlg@yandex.ru>
;; Created: Fri May  4 03:49:22 2018
;; Keywords:

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'telega-core)
(require 'telega-customize)
(require 'telega-ffplay)                ; telega-ffplay-run

(defvar telega-msg-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map [remap self-insert-command] 'ignore)
    (define-key map (kbd "n") 'telega-button-forward)
    (define-key map (kbd "p") 'telega-button-backward)

    (define-key map (kbd "i") 'telega-describe-message)
    (define-key map (kbd "r") 'telega-msg-reply)
    (define-key map (kbd "e") 'telega-msg-edit)
    (define-key map (kbd "f") 'telega-msg-forward)
    (define-key map (kbd "d") 'telega-msg-delete)
    (define-key map (kbd "k") 'telega-msg-delete)
    (define-key map (kbd "l") 'telega-msg-redisplay)
    (define-key map (kbd "R") 'telega-msg-resend)
    (define-key map (kbd "S") 'telega-msg-save)
    (define-key map (kbd "DEL") 'telega-msg-delete)
    map))

(define-button-type 'telega-msg
  :supertype 'telega
  :inserter telega-inserter-for-msg-button
  'read-only t
  'keymap telega-msg-button-map
  'action 'telega-msg-button--action)

(defun telega-msg-button--action (button)
  "Action to take when chat BUTTON is pressed."
  (let ((msg (telega-msg-at button))
        ;; If custom `:action' is used for the button, then use it,
        ;; otherwise open content
        (custom-action (button-get button :action)))
    (cl-assert msg)
    (if custom-action
        (funcall custom-action msg)
      (telega-msg-open-content msg))))

(defun telega-msg--pp (msg)
  "Pretty printer for MSG button."
  (telega-button--insert 'telega-msg msg)
  (telega-ins "\n"))

(defun telega-msg-root--pp (msg)
  "Pretty printer for MSG button shown in root buffer."
  (let ((visible-p (telega-filter-chats nil (list (telega-msg-chat msg)))))
    (when visible-p
      (telega-button--insert 'telega-msg msg
        :inserter 'telega-ins--root-msg
        :action 'telega-msg-goto-highlight)
      (telega-ins "\n"))))

(defun telega-msg--get (chat-id msg-id)
  "Get message by CHAT-ID and MSG-ID pair."
  ;; Optimisation for formatting messages with reply
  (or (with-telega-chatbuf (telega-chat-get chat-id)
        (gethash msg-id telega-chatbuf--messages))

      (let ((reply (telega-server--call
                    (list :@type "getMessage"
                          :chat_id chat-id
                          :message_id msg-id))))
        ;; Probably message already deleted
        (unless (eq (telega--tl-type reply) 'error)
          reply))))

(defsubst telega-msg-list-get (tl-obj-Messages)
  "Return messages list of TL-OBJ-MESSAGES represeting `Messages' object."
  (mapcar #'identity (plist-get tl-obj-Messages :messages)))

(defun telega-msg-at (&optional pos)
  "Return current message at point."
  (let ((button (button-at (or pos (point)))))
    (when (and button (eq (button-type button) 'telega-msg))
      (button-get button :value))))

(defsubst telega-msg-chat (msg)
  "Return chat for the MSG."
  (telega-chat-get (plist-get msg :chat_id)))

(defun telega-msg-reply-msg (msg)
  "Return message MSG replying to."
  (let ((reply-to-msg-id (plist-get msg :reply_to_message_id)))
    (unless (zerop reply-to-msg-id)
      (telega-msg--get (plist-get msg :chat_id) reply-to-msg-id))))

(defsubst telega-msg-goto (msg &optional highlight)
  "Goto message MSG."
  (telega-chat--goto-msg
   (telega-msg-chat msg) (plist-get msg :id) highlight))

(defsubst telega-msg-goto-highlight (msg)
  "Goto message MSG and hightlight it."
  (telega-msg-goto msg 'hightlight))

(defun telega--openMessageContent (msg)
  "Open content of the message MSG."
  (telega-server--send
   (list :@type "openMessageContent"
         :chat_id (plist-get msg :chat_id)
         :message_id (plist-get msg :id))))

(defun telega-msg-open-sticker (msg)
  "Open content for sticker message MSG."
  (let ((sset-id (telega--tl-get msg :content :sticker :set_id)))
    (telega-describe-stickerset
     (telega-stickerset-get sset-id) nil (telega-msg-chat msg))))

(defun telega-msg-open-video (msg)
  "Open content for video message MSG."
  (let* ((video (telega--tl-get msg :content :video))
         (video-file (telega-file--renew video :video)))
    ;; NOTE: `telega-file--download' triggers callback in case file is
    ;; already downloaded
    (telega-file--download video-file 32
      (lambda (file)
        (telega-msg-redisplay msg)
        (when (telega-file--downloaded-p file)
          (apply 'telega-ffplay-run
                 (telega--tl-get file :local :path) nil
                 telega-video-ffplay-args))))))

(defun telega-msg-voice-note--ffplay-callback (msg)
  "Return callback to be used in `telega-ffplay-run'."
  (lambda (progress)
    (telega-msg-redisplay msg)

    (when (not progress)
      ;; DONE (progress==nil)
      ;; If voice message finished playing, then possible play next
      ;; voice message
      (when telega-vvnote-voice-play-next
        (let ((next-voice-msg (telega-chatbuf--next-voice-msg msg)))
          (when next-voice-msg
            (telega-msg-open-content next-voice-msg)))))))

(defun telega-msg-open-voice-note (msg)
  "Open content for voiceNote message MSG."
  ;; - If already playing, then pause
  ;; - If paused, start from paused position
  ;; - If not start, start playing
  (let* ((note (telega--tl-get msg :content :voice_note))
         (note-file (telega-file--renew note :voice))
         (proc (plist-get msg :telega-vvnote-proc)))
    (cl-case (and (process-live-p proc) (process-status proc))
      (run (telega-ffplay-pause proc))
      (stop (telega-ffplay-resume proc))
      (t (telega-file--download note-file 32
          (lambda (file)
            (telega-msg-redisplay msg)
            (when (telega-file--downloaded-p file)
              (plist-put msg :telega-vvnote-proc
                         (telega-ffplay-run
                          (telega--tl-get file :local :path)
                          (telega-msg-voice-note--ffplay-callback msg)
                          "-nodisp")))))))
    ))

(defun telega-msg-open-photo (msg)
  "Open content for photo message MSG."
  (let* ((photo (telega--tl-get msg :content :photo))
         (hr (telega-photo--highres photo))
         (hr-file (telega-file--renew hr :photo)))
    (telega-file--download hr-file 32
      (lambda (file)
        (telega-msg-redisplay msg)
        (when (telega-file--downloaded-p file)
          (find-file (telega--tl-get file :local :path)))))))

(defun telega-msg-open-animation (msg)
  "Open content for animation message MSG."
  (let* ((anim (telega--tl-get msg :content :animation))
         (anim-file (telega-file--renew anim :animation)))
    ;; NOTE: `telega-file--download' triggers callback in case file is
    ;; already downloaded
    (telega-file--download anim-file 32
      (lambda (file)
        (telega-msg-redisplay msg)
        (when (telega-file--downloaded-p file)
          (telega-ffplay-run
           (telega--tl-get file :local :path) nil
           "-loop" "0"))))))

(defun telega-msg-open-content (msg)
  "Open message MSG content."
  (telega--openMessageContent msg)

  (cl-case (telega--tl-type (plist-get msg :content))
    (messageSticker
     (telega-msg-open-sticker msg))
    (messageVideo
     (telega-msg-open-video msg))
    (messageAnimation
     (telega-msg-open-animation msg))
    (messageVoiceNote
     (telega-msg-open-voice-note msg))
    (messagePhoto
     (telega-msg-open-photo msg))
    (messageText
     (let* ((web-page (telega--tl-get msg :content :web_page))
            (url (plist-get web-page :url)))
       (when url
         (telega-browse-url url))))
    (t (message "TODO: `open-content' for <%S>"
                (telega--tl-type (plist-get msg :content))))))

(defun telega--getPublicMessageLink (chat-id msg-id &optional for-album)
  "Get https link to public message."
  (telega-server--call
   (list :@type "getPublicMessageLink"
         :chat_id chat-id
         :message_id msg-id
         :for_album (or for-album :false))))

(defun telega--deleteMessages (chat-id message-ids &optional revoke)
  "Delete message by its id"
  (telega-server--send
   (list :@type "deleteMessages"
         :chat_id chat-id
         :message_ids (cl-map 'vector 'identity message-ids)
         :revoke (or revoke :false))))

(defun telega--forwardMessages (chat-id from-chat-id message-ids
                                        &optional disable-notification
                                        from-background as-album)
  "Forwards previously sent messages.
Returns the forwarded messages.
Return nil if message can't be forwarded."
  (error "`telega--forwardMessages' Not yet implemented"))

(defun telega--searchMessages (query last-msg &optional callback)
  "Search messages by QUERY.
Specify LAST-MSG to continue searching from LAST-MSG searched.
If CALLBACK is specified, then do async call and run CALLBACK
with list of chats received."
  (let ((ret (telega-server--call
              (list :@type "searchMessages"
                    :query query
                    :offset_date (or (plist-get last-msg :date) 0)
                    :offset_chat_id (or (plist-get last-msg :chat_id) 0)
                    :offset_message_id (or (plist-get last-msg :id) 0)
                    :limit 100)
              (and callback
                   `(lambda (reply)
                      (funcall ',callback (telega-msg-list-get reply)))))))
      (if callback
          ret
        (telega-msg-list-get ret))))

(defun telega-msg-chat-title (msg)
  "Title of the message's chat."
  (telega-chat-title (telega-msg-chat msg) 'with-username))

(defsubst telega-msg-sender (msg)
  "Return sender (if any) for message MSG."
  (let ((sender-uid (plist-get msg :sender_user_id)))
    (unless (zerop sender-uid)
      (telega-user--get sender-uid))))

(defsubst telega-msg-by-me-p (msg)
  "Return non-nil if sender of MSG is me."
  (= (plist-get msg :sender_user_id) telega--me-id))

;; DEPRECATED ???
(defun telega-msg-sender-admin-status (msg)
  (let ((admins-tl (telega-server--call
                    (list :@type "getChatAdministrators"
                          :chat_id (plist-get msg :chat_id)))))
    (when (cl-find (plist-get msg :sender_user_id)
                   (plist-get admins-tl :user_ids)
                   :test #'=)
      " (admin)")))

(defun telega-msg--entity-to-properties (entity text)
  (let ((ent-type (plist-get entity :type)))
    (cl-case (telega--tl-type ent-type)
      (textEntityTypeMention
       (list 'face 'telega-entity-type-mention))
      (textEntityTypeMentionName
       (telega-link-props 'user (plist-get ent-type :user_id)
                          'telega-entity-type-mention))
      (textEntityTypeHashtag
       (telega-link-props 'hashtag text))
      (textEntityTypeBold
       (list 'face 'telega-entity-type-bold))
      (textEntityTypeItalic
       (list 'face 'telega-entity-type-italic))
      (textEntityTypeCode
       (list 'face 'telega-entity-type-code))
      (textEntityTypePre
       (list 'face 'telega-entity-type-pre))
      (textEntityTypePreCode
       (list 'face 'telega-entity-type-pre))

      (textEntityTypeUrl
       (telega-link-props 'url text 'telega-entity-type-texturl))
      (textEntityTypeTextUrl
       (telega-link-props 'url (plist-get ent-type :url)
                          'telega-entity-type-texturl))
      )))

(defun telega-msg--ents-to-props (text entities)
  "Convert message TEXT with text ENTITIES to propertized string."
  (mapc (lambda (ent)
          (let* ((beg (plist-get ent :offset))
                 (end (+ (plist-get ent :offset) (plist-get ent :length)))
                 (props (telega-msg--entity-to-properties
                         ent (substring text beg end))))
            (when props
              (add-text-properties beg end props text))))
        entities)
  text)

(defun telega--formattedText (text &optional markdown)
  "Convert TEXT to `formattedTex' type.
If MARKDOWN is non-nil then format TEXT as markdown."
  (if markdown
      (telega-server--call
       (list :@type "parseTextEntities"
             :text text
             :parse_mode (list :@type "textParseModeMarkdown")))
    (list :@type "formattedText"
          :text text :entities [])))


(defun telega-msg-save (msg)
  "Save messages's MSG media content to a file."
  (interactive (list (telega-msg-at (point))))
  (let ((content (plist-get msg :content)))
    (cl-case (telega--tl-type content)
      (t (error "TODO: `telega-msg-save'")))))

(defun telega-describe-message (msg)
  "Show info about message at point."
  (interactive (list (telega-msg-at (point))))
  (with-telega-help-win "*Telegram Message Info*"
    (let ((chat-id (plist-get msg :chat_id))
          (msg-id (plist-get msg :id)))
      (telega-ins "Date(ISO8601): ")
      (telega-ins--date-iso8601 (plist-get msg :date) "\n")
      (telega-ins-fmt "Chat-id: %d\n" chat-id)
      (telega-ins-fmt "Message-id: %d\n" msg-id)
      (let ((sender-uid (plist-get msg :sender_user_id)))
        (unless (zerop sender-uid)
          (telega-ins "Sender: ")
          (insert-text-button (telega-user--name (telega-user--get sender-uid))
                              :telega-link (cons 'user sender-uid))
          (telega-ins "\n")))
      (when (telega-chat--public-p (telega-chat-get chat-id) 'supergroup)
        (let ((link (plist-get
                     (telega--getPublicMessageLink chat-id msg-id) :link)))
          (telega-ins "Link: ")
          (insert-text-button link :telega-link (cons 'url link)
                              'action 'telega-open-link-action)
          (telega-ins "\n")))

      (when telega-debug
        (telega-ins-fmt "MsgSexp: (telega-msg--get %d %d)\n" chat-id msg-id))

      (when telega-debug
        (telega-ins-fmt "\nMessage: %S\n" msg))
      )))

(provide 'telega-msg)

;;; telega-msg.el ends here
