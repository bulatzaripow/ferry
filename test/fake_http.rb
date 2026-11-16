require "json"
require "net/http"
require "stringio"

# Stand-in for Ferry::Http: records requests exactly as they would go over the wire and returns canned replies
class FakeHttp
  Response = Struct.new(:code, :body)

  Request = Struct.new(:method, :url, :token, :body, :wire) do
    def json = JSON.parse(body)
    def path = URI(url).path
  end

  attr_reader :requests, :downloaded

  def initialize(*replies, files: {})
    @replies = replies
    @files = files
    @requests = []
    @downloaded = []
  end

  def request(req)
    wire = StringIO.new
    req.exec(Net::BufferedIO.new(wire), "1.1", req.path)
    @requests << Request.new(req.method, req.uri.to_s, req["Authorization"], req.body, wire.string)

    reply = @replies.shift
    raise reply if reply.is_a?(Exception)

    Response.new(*reply)
  end

  def download(url, io)
    @downloaded << url
    file = @files.fetch(url)
    raise file if file.is_a?(Exception)

    io.write(file)
  end
end