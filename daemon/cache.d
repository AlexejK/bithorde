module daemon.cache;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.io.device.File;
private import tango.io.device.FileMap;
private import tango.io.FilePath;
private import tango.math.random.Random;
private import tango.util.log.Log;

private import daemon.client;
private import daemon.router;
private import lib.asset;
private import lib.client;
private import lib.hashes;
private import message = lib.message;
private import lib.protobuf;
alias message.HashType HashType;

private static ThreadLocal!(ubyte[]) tls_buf;
private static this() {
    tls_buf = new ThreadLocal!(ubyte[]);
}

private static ubyte[] tlsBuffer(uint size) {
    auto buf = tls_buf.val;
    if (buf == (ubyte[]).init) {
        buf = new ubyte[size];
        tls_buf.val = buf;
    } else if (size > buf.length) {
        buf.length = size;
    }
    return buf;
}

class MissingSegmentException : Exception {
    this(char[] msg) { super(msg); }
}

// Note: Doesn't deal with 0-length files
private final class CacheMap {
private:
    struct Segment {
        ulong start;
        ulong end;

        bool isEmpty() { return !end; }
        void opOrAssign(Segment other) {
            if (other.start < this.start)
                this.start = other.start;
            if (this.end < other.end)
                this.end = other.end;
        }
        Segment grow(uint amount=1) {
            return Segment(start?start-amount:start, end+amount);
        }
    }
    Segment[] segments;
    uint segcount;
    MappedFile file;
    FilePath path;
    void ensureIdxAvail(uint length) {
        if (length > segments.length)
            segments = cast(Segment[])file.resize(Segment.sizeof * length);
    }
public:
    this(FilePath path) {
        this.path = path;
        file = new MappedFile(path.toString, File.ReadWriteOpen);
        if (file.length)
            segments = cast(Segment[])file.map();
        else
            segments = cast(Segment[])file.resize(Segment.sizeof * 16);
        for (; !segments[segcount].isEmpty; segcount++) {}
    }

    ~this() {
        if (file)
            file.close();
    }

    /**
     * Check if a segment is covered by the cache.
     */
    bool has(ulong start, uint length) {
        auto end = start+length;
        uint i;
        for (; (i < segcount) && (segments[i].end < start); i++) {}
        if (i==segcount)
            return false;
        else
            return (start>=segments[i].start) && (end<=segments[i].end);
    }

    /**
     * Add a segment to the cachemap
     */
    void add(ulong start, uint length) {
        // Original new segment
        auto onew = Segment(start, start + length);

        // Expand start and end with 1, to cover adjacency
        auto anew = onew.grow(1);

        uint i;
        // Find insertion-point
        for (; (i < segcount) && (segments[i].end <= anew.start); i++) {}
        assert(i <= segcount);

        // Append, Update or Insert ?
        if (i == segcount) {
            // Append
            if ((++segcount) > segments.length)
                ensureIdxAvail(segments.length*2);
            segments[i] = onew;
        } else if (segments[i].start <= anew.end) {
            // Update
            segments[i] |= onew;
        } else {
            // Insert, need to ensure we have space, and shift trailing segments up a position
            if (++segcount > segments.length)
                ensureIdxAvail(segments.length*2);
            for (auto j=segcount;j>i;j--)
                segments[j] = segments[j-1];
            segments[i] = onew;
        }

        // Squash possible trails (merge any intersecting or adjacent segments)
        uint j = i+1;
        for (;(j < segcount) && (segments[j].start <= (segments[i].end+1)); j++)
            segments[i] |= segments[j];

        // Right-shift the rest
        uint shift = j-i-1;
        if (shift) {
            segcount -= shift; // New segcount
            // Shift down valid segments
            for (i+=1; i < segcount; i++)
                segments[i] = segments[i+shift];
            // Zero-fill superfluous segments
            for (;shift; shift--)
                segments[i++] = Segment.init;
        }
    }

    void flush() {
        file.flush();
    }

    /**
     * Returns the size of any block starting at offset 0, or 0, if no such block exists
     */
    ulong zeroBlockSize() {
        if (segments[0].start == 0)
            return segments[0].end;
        else
            return 0;
    }

    unittest {
        auto path = new FilePath("/tmp/bh-unittest-testmap");
        void cleanup() {
            if (path.exists)
                path.remove();
        }
        cleanup();
        scope(exit) cleanup();

        auto map = new CacheMap(path.toString);
        map.add(0,15);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        map.add(30,15);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 45);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);
        map.add(45,5);
        assert(map.segments[1].start == 30);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);
        map.add(25,5);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);

        map.add(18,2);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 15);
        assert(map.segments[1].start == 18);
        assert(map.segments[1].end == 20);
        assert(map.segments[2].start == 25);
        assert(map.segments[2].end == 50);

        map.add(11,7);
        assert(map.segments[0].start == 0);
        assert(map.segments[0].end == 20);
        assert(map.segments[1].start == 25);
        assert(map.segments[1].end == 50);
        assert(map.segments[2].start == 0);
        assert(map.segments[2].end == 0);

        assert(map.has(0,10) == true);
        assert(map.has(1,15) == true);
        assert(map.has(16,15) == false);
        assert(map.has(29,5) == true);
        assert(map.has(30,5) == true);
        assert(map.has(35,5) == true);
        assert(map.has(45,5) == true);
        assert(map.has(46,5) == false);
    }
}

class CachedAsset : public File, IServerAsset {
protected:
    CacheManager mgr;
    FilePath path;
    ubyte[] _id;
    CacheMap cacheMap;
public:
    this(CacheManager mgr, ubyte[] id, bool create = false) {
        // TODO: Merge id and create
        this.mgr = mgr;
        this._id = id.dup;
        this.path = mgr.assetDir.dup.append(bytesToHex(id));

        if (path.exists && create)
            throw new IllegalArgumentException("Trying to create already existing file");

        File.Style style;
        style.open = create ? File.Open.Sedate : File.Open.Exists;
        style.share = File.Share.None;
        style.cache = File.Cache.Random;

        auto idxPath = path.dup.suffix(".idx");
        if (idxPath.exists || create) {
            cacheMap = new CacheMap(idxPath);
            style.access = File.Access.ReadWrite;
        } else {
            style.access = File.Access.Read;
        }

        super(path.toString, style);

        this.mgr.openAssets[this.id] = this;
    }
    ~this() {
        if (cacheMap)
            delete cacheMap;
        close();
        mgr.openAssets.remove(id);
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        if (cacheMap && !cacheMap.has(offset, length))
            throw new MissingSegmentException("Missing given segment");
        ubyte[] buf = tlsBuffer(length);
        seek(offset);
        auto got = super.read(buf);
        cb(this, offset, buf[0..got], message.Status.SUCCESS);
    }

    synchronized void add(ulong offset, ubyte[] data) {
        if (!cacheMap)
            throw new IOException("Trying to write to a completed file");
        seek(offset);
        write(data);
        cacheMap.add(offset, data.length);
    }

    final ulong size() {
        return super.length;
    }

    AssetMetaData metadata() {
        return mgr.localIdMap[id];
    }

    final HashType hashType() { return HashType.init; } // TODO: Change API to support multi-hash
    final AssetId id() { return _id; }

    mixin IRefCounted.Impl;
}

class UploadAsset : CachedAsset {
private:
    Hash[HashType] hashes;
    uint hashingptr;
    File file;
public:
    this(CacheManager mgr, ulong size)
    in { assert(size > 0); }
    body{
        auto tempId = new ubyte[32];
        rand.randomizeUniform!(ubyte[],false)(tempId);
        super(mgr, tempId, true);
        truncate(size);
        foreach (k,hash; HashMap)
            hashes[hash.pbType] = hash.factory();
        mgr.log.trace("Upload started");
    }
    ~this() {
        foreach (hash;hashes)
            delete hash;
        mgr.log.trace("Upload finished");
    }

    synchronized void add(ulong offset, ubyte[] data) {
        super.add(offset, data);
        auto zeroBlockSize = cacheMap.zeroBlockSize;
        if (zeroBlockSize > hashingptr) {
            scope auto newdata = new ubyte[zeroBlockSize - hashingptr];
            seek(hashingptr);
            auto read = read(newdata);
            assert(read == newdata.length);
            foreach (hash; hashes) {
                hash.update(newdata);
            }
            if (zeroBlockSize == length)
                finish();
            else
                hashingptr = zeroBlockSize;
        }
    }

private:
    void finish() {
        assert(cacheMap.segcount == 1);
        assert(cacheMap.segments[0].start == 0);
        assert(cacheMap.segments[0].end == length);
        auto asset = new AssetMetaData;
        asset.localId = _id.dup;
        
        foreach (type, hash; hashes) {
            auto digest = hash.digest;
            auto hashId = new message.Identifier;
            hashId.type = type;
            hashId.id = digest.dup;
            asset.hashIds ~= hashId;
        }

        mgr.addToIdMap(asset);
        
        cacheMap.path.remove();
        delete cacheMap;
    }
}

class AssetMetaData : ProtoBufMessage {
    ubyte[] localId;        // Local assetId
    message.Identifier[] hashIds;   // HashIds
    mixin MessageMixin!(PBField!("localId",   1)(),
                        PBField!("hashIds",   2)());

    char[] toString() {
        char[] retval = "AssetMetaData {\n";
        retval ~= "     localId: " ~ bytesToHex(localId) ~ "\n";
        foreach (hash; hashIds) {
            retval ~= "     " ~ HashMap[hash.type].name ~ ": " ~ bytesToHex(hash.id) ~ "\n";
        }
        return retval ~ "}";
    }
}

private class IdMap {
    AssetMetaData[] assets;
    mixin MessageMixin!(PBField!("assets",    1)());
}

class CacheManager : IAssetSource {
protected:
    CachedAsset[ubyte[]] openAssets;
    AssetMetaData hashIdMap[HashType][ubyte[]];
    AssetMetaData localIdMap[ubyte[]];
    FilePath assetDir;
    FilePath idMapPath;
    Router router;
    static Logger log;

static this() {
    log = Log.lookup("daemon.cache");
}
public:
    this(char[] assetDir, Router router) {
        this.assetDir = new FilePath(assetDir);
        this.router = router;

        idMapPath = this.assetDir.dup.append("index.protobuf");
        if (idMapPath.exists)
            loadIdMap();
        else {
            hashIdMap[message.HashType.SHA1] = null;
            hashIdMap[message.HashType.SHA256] = null;
            hashIdMap[message.HashType.TREE_TIGER] = null;
            hashIdMap[message.HashType.ED2K] = null;
        }
    }
    IServerAsset findAsset(OpenRequest req) {
        IServerAsset fromCache(CachedAsset asset) {
            asset.takeRef();
            log.trace("serving {} from cache", bytesToHex(asset.id));
            req.callback(asset, message.Status.SUCCESS);
            return asset;
        }
        IServerAsset forwardRequest() {
            return router.findAsset(req);
        }

        ubyte[] localId;
        foreach (id; req.ids) {
            if (id.id in hashIdMap[id.type]) {
                auto assetMeta = hashIdMap[id.type][id.id];
                localId = assetMeta.localId;
                break;
            }
        }
        if (!localId) {
            log.trace("Unknown asset, forwarding {}", req);
            return forwardRequest();
        }

        if (auto asset = localId in openAssets) {
            return fromCache(*asset);
        } else {
            try {
                auto newAsset = new CachedAsset(this, localId);
                return fromCache(newAsset);
            } catch (IOException e) {
                log.error("While opening asset: {}", e);
                return null;
            }
        }
    }
    UploadAsset uploadAsset(UploadRequest req) {
        try {
            auto newAsset = new UploadAsset(this, req.size);
            newAsset.takeRef();
            return newAsset;
        } catch (IOException e) {
            log.error("While opening upload asset: {}", e);
            return null;
        }
    }
private:
    void loadIdMap() {
        scope auto mapsrc = new IdMap();
        scope auto fileContent = cast(ubyte[])File.get(idMapPath.toString);
        mapsrc.decode(fileContent);
        foreach (asset; mapsrc.assets) {
            localIdMap[asset.localId] = asset;
            foreach (id; asset.hashIds)
                hashIdMap[id.type][id.id] = asset;
        }
    }

    void saveIdMap() {
        scope auto map = new IdMap;
        map.assets = localIdMap.values;
        File.set(idMapPath.toString, map.encode());
    }

    void addToIdMap(AssetMetaData asset) {
        localIdMap[asset.localId] = asset;
        foreach (id; asset.hashIds) {
            hashIdMap[id.type][id.id] = asset;
        }
        saveIdMap();
    }
}