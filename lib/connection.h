#ifndef BITHORDE_CONNECTION_H
#define BITHORDE_CONNECTION_H

#include <queue>

#include <boost/asio/io_service.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/local/stream_protocol.hpp>
#include <boost/signals2.hpp>
#include <boost/smart_ptr/enable_shared_from_this.hpp>

#include "bithorde.pb.h"
#include "types.h"

namespace bithorde {

class Connection
	: public boost::enable_shared_from_this<Connection>
{
public:
	typedef boost::shared_ptr<Connection> Pointer;

	enum MessageType {
		HandShake = 1,
		BindRead = 2,
		AssetStatus = 3,
		ReadRequest = 5,
		ReadResponse = 6,
		BindWrite = 7,
		DataSegment = 8,
		HandShakeConfirmed = 9,
		Ping = 10,
	};
	enum State {
		Connecting,
		Connected,
		AwaitingAuth,
		Authenticated,
	};

	static Pointer create(boost::asio::io_service& ioSvc, const boost::asio::ip::tcp::endpoint& addr);
	static Pointer create(boost::asio::io_service& ioSvc, boost::shared_ptr< boost::asio::ip::tcp::socket >& socket);
	static Pointer create(boost::asio::io_service& ioSvc, const boost::asio::local::stream_protocol::endpoint& addr);
	static Pointer create(boost::asio::io_service& ioSvc, boost::shared_ptr< boost::asio::local::stream_protocol::socket >& socket);

	typedef boost::signals2::signal<void ()> VoidSignal;
	typedef boost::signals2::signal<void (MessageType, ::google::protobuf::Message&)> MessageSignal;
	VoidSignal disconnected;
	MessageSignal message;
	VoidSignal writable;

	bool sendMessage(MessageType type, const ::google::protobuf::Message & msg, bool prioritized=false);

	virtual void close() = 0;

protected:
	Connection(boost::asio::io_service& ioSvc);

	virtual void trySend() = 0;
	virtual void tryRead() = 0;
	
	void onRead(const boost::system::error_code& err, size_t count);
	void onWritten(const boost::system::error_code& err, size_t count);

	bool encode(Connection::MessageType type, const::google::protobuf::Message &msg);

protected:
	State _state;

	boost::asio::io_service& _ioSvc;

	Buffer _rcvBuf;
	Buffer _sendBuf;

private:
	template <class T> bool dequeue(MessageType type, ::google::protobuf::io::CodedInputStream &stream);
};

}

#endif // BITHORDE_CONNECTION_H
