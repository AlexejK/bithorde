
#include "bhupload.h"

#include <iostream>
#include <list>
#include <sstream>
#include <utility>

#include "buildconf.hpp"

namespace asio = boost::asio;
namespace po = boost::program_options;
namespace fs = boost::filesystem;
using namespace std;

using namespace bithorde;

const static size_t BLOCK_SIZE = (64*1024);

BHUpload::BHUpload(boost::program_options::variables_map &args) :
	optConnectUrl(args["url"].as<string>()),
	optLink(args.count("link")),
	optMyName(args["name"].as<string>()),
	optQuiet(args.count("quiet")),
	_currentAsset(NULL)
{
	_readBuf.allocate(BLOCK_SIZE);
}

int BHUpload::main(const std::vector<std::string>& args) {
	std::vector<std::string>::const_iterator iter;
	for (iter = args.begin(); iter != args.end(); iter++) {
		if (!queueFile(*iter))
			return -1;
	}

	_client = Client::create(_ioSvc, optMyName);
	_client->authenticated.connect(boost::bind(&BHUpload::onAuthenticated, this, _1));
	_client->connect(optConnectUrl);

	_ioSvc.run();

	return 0;
}

bool BHUpload::queueFile(const std::string& path) {
	fs::path p(path);
	if (!fs::exists(p)) {
		cerr << "Non-existing file '" << path << "'" << endl;
		return false;
	}
	if (!(fs::is_regular_file(p) || fs::is_symlink(p))) {
		cerr <<  "Path is not regular file '" << path << "'" << endl;
		return false;
	}

	_files.push_back(path);
	return true;
}

void BHUpload::nextAsset() {
	if (_currentAsset) {
		_currentAsset->close();
		delete _currentAsset;
		_currentAsset = NULL;
	}
	if (_currentFile.is_open())
		_currentFile.close();

	if (_files.empty()) {
		_ioSvc.stop();
	} else {
		fs::path& p = _files.front();
		_currentFile.open(p.c_str(), ifstream::in | ifstream::binary);
		if (optLink)
			_currentAsset = new UploadAsset(_client, p);
		else
			_currentAsset = new UploadAsset(_client, fs::file_size(p));
		_currentAsset->statusUpdate.connect(boost::bind(&BHUpload::onStatusUpdate, this, _1));
		_client->bind(*_currentAsset);

		_currentOffset = 0;
		_files.pop_front();
	}
}

void BHUpload::onStatusUpdate(const bithorde::AssetStatus& status)
{
	switch (status.status()) {
	case bithorde::SUCCESS:
		if (status.ids_size()) {
			cout << MagnetURI(status) << endl;
			nextAsset();
		} else if (!optLink) {
			cerr << "Uploading ..." << endl;
			_writeConnection = _client->writable.connect(boost::bind(&BHUpload::onWritable, this));
			onWritable();
		}
		break;
	default:
		cerr << "Failed ..." << endl;
		nextAsset();
		break;
	}
}

void BHUpload::onWritable()
{
	while (tryWrite());
}

ssize_t BHUpload::readNext()
{
	_currentFile.read((char*)_readBuf.ptr, _readBuf.capacity);
	streamsize read = _currentFile.gcount();
	_readBuf.charge(read);
	return read;
}

bool BHUpload::tryWrite() {
	if (!_readBuf.size && !readNext()) {
		cerr << "Done, awaiting asset-ids..." << endl;
		// File reading done. Don't try to write before next is ready for upload.
		_writeConnection.disconnect();
		return false;
	}

	if (_currentAsset->tryWrite(_currentOffset, _readBuf.ptr, _readBuf.size)) {
		_currentOffset += _readBuf.size;
		// TODO: Update progressbar
		_readBuf.pop(_readBuf.size);
		return true;
	} else {
		return false;
	}
}

void BHUpload::onAuthenticated(string& peerName) {
	cerr << "Connected to " << peerName << endl;
	nextAsset();
}

int main(int argc, char *argv[]) {
	po::options_description desc("Supported options");
	desc.add_options()
		("help,h",
			"Show help")
		("version,v",
			"Show version")
		("name,n", po::value< string >()->default_value("bhupload"),
			"Bithorde-name of this client")
		("quiet,q",
			"Don't show progressbar")
		("url,u", po::value< string >()->default_value("/tmp/bithorde"),
			"Where to connect to bithorde. Either host:port, or /path/socket")
		("link,l",
			"Add asset-link, instead of uploading asset data")
		("file", po::value< vector<string> >(), "file(s) to upload or request link for")
	;
	po::positional_options_description p;
	p.add("file", -1);

	po::command_line_parser parser(argc, argv);
	parser.options(desc).positional(p);

	po::variables_map vm;
	po::store(parser.run(), vm);
	po::notify(vm);

	if (vm.count("version"))
		return bithorde::exit_version();

	if (vm.count("help") || !vm.count("file")) {
		cerr << desc << endl;
		return 1;
	}

	BHUpload app(vm);

	int res = app.main(vm["file"].as< vector<string> >());
	cerr.flush();
	return res;
}
