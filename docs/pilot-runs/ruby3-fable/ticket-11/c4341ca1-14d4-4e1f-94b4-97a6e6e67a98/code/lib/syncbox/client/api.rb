# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Syncbox
  module Client
    # HTTP API сервера глазами клиента: одно keep-alive соединение на всё
    # время работы команды (после сбоя запроса Net::HTTP закрывает сокет и
    # на следующем запросе соединяется заново). Любая сетевая ошибка или
    # ответ не из контракта превращается в исключение с понятным сообщением:
    #   - ServerUnreachable — до сервера не достучаться: имя не резолвится,
    #     соединение отклонено, нет маршрута, таймаут соединения;
    #   - Error — сбой конкретного запроса: сервер оборвал соединение, не
    #     ответил в срок, ответил не тем кодом или не тем телом. Команды
    #     считают его сбоем одного файла и продолжают с остальными.
    class Api
      OCTET_STREAM = "application/octet-stream"

      # Таймауты сетевых операций в секундах: без них клиент висел бы на
      # молчащем сервере бесконечно. open — установка соединения (включая
      # разрешение имени), read — ожидание ответа, write — отправка данных.
      # Флагов и переменных для них нет (спецификация не предусматривает);
      # тесты подменяют Api.timeouts.
      DEFAULT_TIMEOUTS = { open: 10, read: 60, write: 60 }.freeze

      # Сколько байт тела неожиданного ответа показывать в сообщении об ошибке.
      ERROR_BODY_LIMIT = 200

      # Ошибки, означающие, что сервера нет вовсе: возникают при установке
      # соединения, а не на уже открытом.
      UNREACHABLE_ERRORS = [
        SocketError, Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
        Errno::ENETDOWN, Errno::EHOSTDOWN, Errno::EADDRNOTAVAIL
      ].freeze

      # Все сетевые ошибки, которые может поднять Net::HTTP.
      NETWORK_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError, Timeout::Error,
        Net::ProtocolError, OpenSSL::SSL::SSLError
      ].freeze

      # Ошибка потребителя тела ответа (блока get_blob, например запись на
      # диск) — не сетевая. Обёртка проносит её сквозь обработку сетевых
      # ошибок в request как есть, чтобы ENOSPC при записи не выглядел как
      # «request failed».
      class ConsumerError < StandardError
        attr_reader :error

        def initialize(error)
          @error = error
          super(error.message)
        end
      end
      private_constant :ConsumerError

      def self.timeouts
        DEFAULT_TIMEOUTS
      end

      # Открывает соединение с сервером на время блока; не удалось — ServerUnreachable.
      def self.open(base_url)
        api = new(base_url)
        api.connect
        begin
          yield api
        ensure
          api.close
        end
      end

      # Понятная причина сетевой ошибки для сообщений.
      def self.describe_error(error)
        case error
        when Net::OpenTimeout then "connection timed out after #{timeouts[:open]}s"
        when Net::ReadTimeout then "server did not respond within #{timeouts[:read]}s (read timeout)"
        when Net::WriteTimeout then "server did not accept data within #{timeouts[:write]}s (write timeout)"
        when EOFError then "server closed the connection without a complete response"
        else
          # Net::HTTP оборачивает ошибку соединения в «Failed to open TCP
          # connection to host:port (<причина>)»; адрес в сообщении уже есть.
          error.message.sub(/\AFailed to open TCP connection to \S+ \((.*)\)\z/m, '\1')
        end
      end

      # key → путь в URL. В сегментах остаются как есть только unreserved
      # символы RFC 3986, всё прочее (включая не-ASCII) percent-кодируется
      # побайтно. `/` между сегментами не кодируется: сервер декодирует key
      # однократно, и `%2F` превратился бы в разделитель.
      def self.escape_key(key)
        key.split("/", -1).map { |segment| escape_segment(segment) }.join("/")
      end

      def self.escape_segment(segment)
        segment.b.gsub(/[^A-Za-z0-9\-._~]/) { |byte| format("%%%02X", byte.ord) }
      end

      def initialize(base_url)
        @base_url = base_url
        @prefix = base_url.path
        @http = Net::HTTP.new(base_url.host, base_url.port)
        @http.use_ssl = base_url.scheme == "https"
        timeouts = self.class.timeouts
        @http.open_timeout = timeouts[:open]
        @http.read_timeout = timeouts[:read]
        @http.write_timeout = timeouts[:write]
        # Net::HTTP по умолчанию молча повторяет идемпотентные запросы после
        # сетевой ошибки. Повторы спецификацией не предусмотрены, а для PUT с
        # потоковым телом повтор и невозможен — сбой запроса виден сразу.
        @http.max_retries = 0
      end

      def connect
        @http.start unless @http.started?
      rescue *NETWORK_ERRORS => e
        raise ServerUnreachable, "cannot connect to server #{@base_url}: #{self.class.describe_error(e)}"
      end

      def close
        @http.finish if @http.started?
      rescue IOError
        nil
      end

      # GET /blobs → массив { "key", "size", "sha256", "modified_at" }.
      def list_blobs
        label = "GET /blobs"
        response = request(label, Net::HTTP::Get.new("#{@prefix}/blobs"))
        expect!(label, response, "200")
        list = parse_json(label, response)
        raise Error, "#{label}: expected a JSON array, got #{list.class}" unless list.is_a?(Array)

        list
      end

      # PUT /blobs/{key} с телом из io (ровно size байт, потоково, без
      # загрузки файла в память) → { "key", "sha256", "size" }.
      def put_blob(key, io, size)
        label = "PUT /blobs/#{key}"
        request = Net::HTTP::Put.new("#{@prefix}/blobs/#{self.class.escape_key(key)}",
                                     "content-type" => OCTET_STREAM, "content-length" => size.to_s)
        request.body_stream = io
        response = request(label, request)
        expect!(label, response, "201")
        parse_json(label, response)
      end

      # GET /blobs/{key}: тело ответа отдаётся блоку кусками по мере чтения
      # из сокета, без загрузки блоба в память. Возвращает число полученных
      # байт. Любой ответ, кроме 200 (в том числе 404), — Error. Ошибка
      # самого блока поднимается как есть.
      def get_blob(key)
        label = "GET /blobs/#{key}"
        req = Net::HTTP::Get.new("#{@prefix}/blobs/#{self.class.escape_key(key)}")
        size = 0
        request(label, req) do |response|
          if response.code == "200"
            response.read_body do |chunk|
              next if chunk.empty? # Net::HTTP отдаёт пустой кусок для Content-Length: 0

              size += chunk.bytesize
              begin
                yield chunk
              rescue StandardError => e
                raise ConsumerError, e
              end
            end
          else
            # Тело ошибки небольшое — дочитываем его целиком, чтобы соединение
            # осталось пригодным для следующих запросов, и только потом падаем.
            response.read_body
            expect!(label, response, "200")
          end
        end
        size
      rescue ConsumerError => e
        raise e.error
      end

      private

      # Без блока — обычный запрос с буферизованным телом. С блоком — тело
      # читается внутри блока (потоково), блок получает Net::HTTPResponse.
      def request(label, req, &block)
        @http.request(req, &block)
      rescue *UNREACHABLE_ERRORS => e
        # Соединение после прошлого сбоя закрыто, и открыть новое не вышло.
        raise ServerUnreachable, "cannot connect to server #{@base_url}: #{self.class.describe_error(e)}"
      rescue *NETWORK_ERRORS => e
        raise Error, "#{label}: request to #{@base_url} failed: #{self.class.describe_error(e)}"
      end

      def expect!(label, response, code)
        return if response.code == code

        raise Error, "#{label}: server responded #{response.code}#{describe(response)}"
      end

      # Короткое описание тела неожиданного ответа: message из JSON-ошибки
      # сервера, иначе обрезанное тело.
      def describe(response)
        body = response.body.to_s
        return "" if body.empty?

        text = begin
          payload = JSON.parse(body)
          payload.is_a?(Hash) ? (payload["message"] || payload["error"]) : nil
        rescue JSON::ParserError
          nil
        end
        ": #{text || body.b[0, ERROR_BODY_LIMIT].scrub}"
      end

      def parse_json(label, response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise Error, "#{label}: server returned invalid JSON: #{e.message}"
      end
    end
  end
end
