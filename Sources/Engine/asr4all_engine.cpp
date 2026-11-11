#include "asr4all_engine.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>
#include <vector>

#include "onnxruntime_cxx_api.h"

namespace {

// ---------------------------------------------------------------------------
// Minimal self-contained JSON parser (sufficient for metadata.json)
// ---------------------------------------------------------------------------

struct JsonValue {
    enum class Type { Null, Bool, Number, String, Array, Object };
    Type type = Type::Null;
    bool boolVal = false;
    double numVal = 0.0;
    std::string strVal;
    std::vector<JsonValue> arrVal;
    std::map<std::string, JsonValue> objVal;

    bool isNull() const { return type == Type::Null; }
    bool isObject() const { return type == Type::Object; }
    bool isArray() const { return type == Type::Array; }
    bool isString() const { return type == Type::String; }

    const JsonValue* get(const std::string& key) const {
        if (type != Type::Object) return nullptr;
        auto it = objVal.find(key);
        return it == objVal.end() ? nullptr : &it->second;
    }

    std::string asString(const std::string& def = "") const {
        return type == Type::String ? strVal : def;
    }

    int64_t asInt(int64_t def = 0) const {
        if (type == Type::Number) return static_cast<int64_t>(numVal);
        if (type == Type::String) {
            try {
                return std::stoll(strVal);
            } catch (...) {
                return def;
            }
        }
        return def;
    }

    bool asBool(bool def = false) const {
        return type == Type::Bool ? boolVal : def;
    }
};

class JsonParser {
public:
    explicit JsonParser(const std::string& src) : s_(src), pos_(0) {}

    JsonValue parse() {
        skipWs();
        JsonValue v = parseValue();
        skipWs();
        return v;
    }

private:
    const std::string& s_;
    size_t pos_;

    void skipWs() {
        while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r')) {
            ++pos_;
        }
    }

    char peek() const { return pos_ < s_.size() ? s_[pos_] : '\0'; }
    char next() {
        if (pos_ >= s_.size()) throw std::runtime_error("Unexpected end of JSON");
        return s_[pos_++];
    }

    void appendUtf8(std::string& out, uint32_t cp) {
        if (cp <= 0x7F) {
            out.push_back(static_cast<char>(cp));
        } else if (cp <= 0x7FF) {
            out.push_back(static_cast<char>(0xC0 | ((cp >> 6) & 0x1F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp <= 0xFFFF) {
            out.push_back(static_cast<char>(0xE0 | ((cp >> 12) & 0x0F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | ((cp >> 18) & 0x07)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    uint32_t parseHex4() {
        uint32_t val = 0;
        for (int i = 0; i < 4; ++i) {
            char c = next();
            val <<= 4;
            if (c >= '0' && c <= '9') val |= (c - '0');
            else if (c >= 'a' && c <= 'f') val |= (c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') val |= (c - 'A' + 10);
            else throw std::runtime_error("Invalid unicode escape in JSON");
        }
        return val;
    }

    std::string parseString() {
        if (next() != '"') throw std::runtime_error("Expected '\"'");
        std::string out;
        while (true) {
            char c = next();
            if (c == '"') break;
            if (c == '\\') {
                char esc = next();
                switch (esc) {
                    case '"': out.push_back('"'); break;
                    case '\\': out.push_back('\\'); break;
                    case '/': out.push_back('/'); break;
                    case 'b': out.push_back('\b'); break;
                    case 'f': out.push_back('\f'); break;
                    case 'n': out.push_back('\n'); break;
                    case 'r': out.push_back('\r'); break;
                    case 't': out.push_back('\t'); break;
                    case 'u': {
                        uint32_t cp = parseHex4();
                        if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 2 <= s_.size() && s_[pos_] == '\\' && s_[pos_ + 1] == 'u') {
                            pos_ += 2;
                            uint32_t low = parseHex4();
                            if (low >= 0xDC00 && low <= 0xDFFF) {
                                cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
                            }
                        }
                        appendUtf8(out, cp);
                        break;
                    }
                    default:
                        out.push_back(esc);
                        break;
                }
            } else {
                out.push_back(c);
            }
        }
        return out;
    }

    JsonValue parseValue() {
        skipWs();
        char c = peek();
        if (c == '{') {
            next();
            JsonValue obj;
            obj.type = JsonValue::Type::Object;
            skipWs();
            if (peek() == '}') {
                next();
                return obj;
            }
            while (true) {
                skipWs();
                std::string key = parseString();
                skipWs();
                if (next() != ':') throw std::runtime_error("Expected ':' in JSON object");
                obj.objVal.emplace(std::move(key), parseValue());
                skipWs();
                char sep = next();
                if (sep == '}') break;
                if (sep != ',') throw std::runtime_error("Expected ',' or '}' in JSON object");
            }
            return obj;
        }
        if (c == '[') {
            next();
            JsonValue arr;
            arr.type = JsonValue::Type::Array;
            skipWs();
            if (peek() == ']') {
                next();
                return arr;
            }
            while (true) {
                arr.arrVal.push_back(parseValue());
                skipWs();
                char sep = next();
                if (sep == ']') break;
                if (sep != ',') throw std::runtime_error("Expected ',' or ']' in JSON array");
            }
            return arr;
        }
        if (c == '"') {
            JsonValue v;
            v.type = JsonValue::Type::String;
            v.strVal = parseString();
            return v;
        }
        if (c == 't') {
            if (s_.compare(pos_, 4, "true") != 0) throw std::runtime_error("Invalid JSON literal");
            pos_ += 4;
            JsonValue v;
            v.type = JsonValue::Type::Bool;
            v.boolVal = true;
            return v;
        }
        if (c == 'f') {
            if (s_.compare(pos_, 5, "false") != 0) throw std::runtime_error("Invalid JSON literal");
            pos_ += 5;
            JsonValue v;
            v.type = JsonValue::Type::Bool;
            v.boolVal = false;
            return v;
        }
        if (c == 'n') {
            if (s_.compare(pos_, 4, "null") != 0) throw std::runtime_error("Invalid JSON literal");
            pos_ += 4;
            return JsonValue{};
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            size_t start = pos_;
            if (s_[pos_] == '-') ++pos_;
            while (pos_ < s_.size() && (std::isdigit(static_cast<unsigned char>(s_[pos_])) || s_[pos_] == '.' ||
                                        s_[pos_] == 'e' || s_[pos_] == 'E' || s_[pos_] == '+' || s_[pos_] == '-')) {
                ++pos_;
            }
            JsonValue v;
            v.type = JsonValue::Type::Number;
            v.numVal = std::stod(s_.substr(start, pos_ - start));
            return v;
        }
        throw std::runtime_error("Unexpected character in JSON");
    }
};

// ---------------------------------------------------------------------------
// Minimal ONNX protobuf external-data inspector (matches asr4all_onnx.py)
// ---------------------------------------------------------------------------

struct ExternalTensorSpec {
    std::string name;
    int32_t onnxDtype = 0;
    std::vector<int64_t> dims;
    uint64_t offset = 0;
    uint64_t length = 0;
};

uint64_t parseStrictUint64(const std::string& s, const char* fieldName) {
    if (s.empty()) {
        throw std::runtime_error(std::string("Empty integer field: ") + fieldName);
    }
    for (unsigned char ch : s) {
        if (ch < '0' || ch > '9') {
            throw std::runtime_error(std::string("Invalid unsigned integer in ") + fieldName);
        }
    }
    errno = 0;
    char* end = nullptr;
    unsigned long long val = std::strtoull(s.c_str(), &end, 10);
    if (errno == ERANGE || end != s.c_str() + s.size()) {
        throw std::runtime_error(std::string("Integer overflow in ") + fieldName);
    }
    return static_cast<uint64_t>(val);
}

bool isSafeRelativeBundlePath(const std::string& rel) {
    if (rel.empty() || rel[0] == '/') return false;
    size_t i = 0;
    while (i <= rel.size()) {
        size_t slash = rel.find('/', i);
        size_t end = (slash == std::string::npos) ? rel.size() : slash;
        std::string seg = rel.substr(i, end - i);
        if (seg.empty() || seg == "." || seg == ".." || seg.find('\\') != std::string::npos || seg.find('\0') != std::string::npos) {
            return false;
        }
        if (slash == std::string::npos) break;
        i = slash + 1;
    }
    return true;
}

uint64_t readVarint(const uint8_t* buf, size_t len, size_t& i) {
    uint64_t val = 0;
    int shift = 0;
    while (i < len) {
        uint8_t b = buf[i++];
        val |= static_cast<uint64_t>(b & 0x7F) << shift;
        if ((b & 0x80) == 0) return val;
        shift += 7;
        if (shift > 63) throw std::runtime_error("Malformed protobuf varint");
    }
    throw std::runtime_error("Truncated protobuf varint");
}

template <typename Fn>
void walkProtobufFields(const uint8_t* buf, size_t len, Fn&& fn) {
    size_t i = 0;
    while (i < len) {
        uint64_t key = readVarint(buf, len, i);
        uint32_t fieldNum = static_cast<uint32_t>(key >> 3);
        uint32_t wireType = static_cast<uint32_t>(key & 7);
        if (wireType == 0) {
            uint64_t val = readVarint(buf, len, i);
            fn(fieldNum, wireType, val, nullptr, size_t{0});
        } else if (wireType == 2) {
            uint64_t n = readVarint(buf, len, i);
            if (i + n > len) throw std::runtime_error("Truncated protobuf length-delimited field");
            fn(fieldNum, wireType, uint64_t{0}, buf + i, static_cast<size_t>(n));
            i += static_cast<size_t>(n);
        } else if (wireType == 1) {
            if (i + 8 > len) throw std::runtime_error("Truncated protobuf fixed64");
            i += 8;
        } else if (wireType == 5) {
            if (i + 4 > len) throw std::runtime_error("Truncated protobuf fixed32");
            i += 4;
        } else {
            throw std::runtime_error("Unsupported protobuf wire type");
        }
    }
}

std::vector<ExternalTensorSpec> parseExternalTensors(const uint8_t* modelBytes, size_t modelLen) {
    std::vector<ExternalTensorSpec> out;
    walkProtobufFields(modelBytes, modelLen, [&](uint32_t num, uint32_t wt, uint64_t, const uint8_t* graphPtr, size_t graphLen) {
        if (num != 7 || wt != 2) return; // ModelProto.graph = 7
        walkProtobufFields(graphPtr, graphLen, [&](uint32_t gnum, uint32_t gwt, uint64_t, const uint8_t* tensorPtr, size_t tensorLen) {
            if (gnum != 5 || gwt != 2) return; // GraphProto.initializer = 5
            ExternalTensorSpec spec;
            uint64_t location = 0;
            std::string offsetStr;
            std::string lengthStr;
            walkProtobufFields(tensorPtr, tensorLen, [&](uint32_t tnum, uint32_t twt, uint64_t tval, const uint8_t* ptr, size_t plen) {
                if (tnum == 1) { // dims
                    if (twt == 0) {
                        spec.dims.push_back(static_cast<int64_t>(tval));
                    } else if (twt == 2) {
                        size_t j = 0;
                        while (j < plen) {
                            spec.dims.push_back(static_cast<int64_t>(readVarint(ptr, plen, j)));
                        }
                    }
                } else if (tnum == 2 && twt == 0) { // data_type
                    spec.onnxDtype = static_cast<int32_t>(tval);
                } else if (tnum == 8 && twt == 2) { // name
                    spec.name.assign(reinterpret_cast<const char*>(ptr), plen);
                } else if (tnum == 13 && twt == 2) { // external_data (StringStringEntryProto: key=1, val=2)
                    std::string k, v;
                    walkProtobufFields(ptr, plen, [&](uint32_t knum, uint32_t kwt, uint64_t, const uint8_t* kptr, size_t klen) {
                        if (knum == 1 && kwt == 2) k.assign(reinterpret_cast<const char*>(kptr), klen);
                        else if (knum == 2 && kwt == 2) v.assign(reinterpret_cast<const char*>(kptr), klen);
                    });
                    if (k == "offset") offsetStr = std::move(v);
                    else if (k == "length") lengthStr = std::move(v);
                } else if (tnum == 14 && twt == 0) { // data_location (1 = EXTERNAL)
                    location = tval;
                }
            });
            if (location == 1 && !spec.name.empty() && !lengthStr.empty()) {
                spec.offset = offsetStr.empty() ? 0ULL : parseStrictUint64(offsetStr, "external_data.offset");
                spec.length = parseStrictUint64(lengthStr, "external_data.length");
                out.push_back(std::move(spec));
            }
        });
    });
    return out;
}

ONNXTensorElementDataType mapOnnxDtype(int32_t onnxDtype) {
    switch (onnxDtype) {
        case 1: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
        case 6: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32;
        case 7: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
        case 9: return ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL;
        case 10: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16;
        case 11: return ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE;
        default: throw std::runtime_error("Unsupported ONNX initializer dtype: " + std::to_string(onnxDtype));
    }
}

std::string readFileString(const std::string& path) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) throw std::runtime_error("Failed to open file: " + path);
    std::ostringstream oss;
    oss << ifs.rdbuf();
    return oss.str();
}

std::vector<uint8_t> readFileBytes(const std::string& path) {
    std::ifstream ifs(path, std::ios::binary | std::ios::ate);
    if (!ifs) throw std::runtime_error("Failed to open file: " + path);
    auto sz = ifs.tellg();
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(static_cast<size_t>(sz));
    if (sz > 0 && !ifs.read(reinterpret_cast<char*>(buf.data()), sz)) {
        throw std::runtime_error("Failed to read file: " + path);
    }
    return buf;
}

Ort::Env& sharedOrtEnv() {
    static Ort::Env env(ORT_LOGGING_LEVEL_ERROR, "voiceboy-asr4all");
    return env;
}

struct TensorDesc {
    std::string name;
    ONNXTensorElementDataType elemType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    std::vector<int64_t> shape;
};

struct LoadedSession {
    std::unique_ptr<Ort::Session> session;
    std::vector<TensorDesc> inputs;
    std::vector<TensorDesc> outputs;
    std::unordered_map<std::string, size_t> inputByName;
    std::unordered_map<std::string, size_t> outputByName;
};

struct PcecRungMeta {
    std::string name;
    std::string flushName;
};

struct TierInfo {
    std::string name;
    std::string pcecRungKey;
    int64_t windowSamples = 0;
    int64_t commitFrames = 0;
    int64_t lookaheadFrames = 0;
    int64_t hiddenDim = 0;
    bool hasHidden = false;
};

struct TensorBuffer {
    ONNXTensorElementDataType elemType = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
    std::vector<int64_t> shape;
    std::vector<uint8_t> raw;

    static TensorBuffer zeros(const TensorDesc& desc) {
        TensorBuffer buf;
        buf.elemType = desc.elemType;
        buf.shape = desc.shape;
        size_t numel = 1;
        for (int64_t d : desc.shape) {
            numel *= static_cast<size_t>(std::max<int64_t>(1, d));
        }
        size_t elemSize = 4;
        switch (desc.elemType) {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: elemSize = 8; break;
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE: elemSize = 8; break;
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16: elemSize = 2; break;
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: elemSize = 1; break;
            default: elemSize = 4; break;
        }
        buf.raw.assign(numel * elemSize, 0);
        return buf;
    }

    Ort::Value asOrtValue(const Ort::MemoryInfo& memInfo) {
        return Ort::Value::CreateTensor(
            memInfo,
            raw.data(),
            raw.size(),
            shape.data(),
            shape.size(),
            elemType
        );
    }
};

constexpr int kPauseThresholds[] = {1, 2, 4, 8, 16, 32, 64, 128};

int pauseBucket(int blanks) {
    int b = 0;
    for (int t : kPauseThresholds) {
        if (blanks >= t) ++b;
    }
    return b;
}

std::string trimAscii(const std::string& s) {
    size_t start = 0;
    while (start < s.size() && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r')) {
        ++start;
    }
    size_t end = s.size();
    while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\n' || s[end - 1] == '\r')) {
        --end;
    }
    return s.substr(start, end - start);
}

std::string toUpperAscii(std::string s) {
    for (char& c : s) {
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    return s;
}

std::string capFirstAscii(std::string s) {
    if (!s.empty()) {
        s[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(s[0])));
    }
    return s;
}

void writeErr(char* errBuf, size_t errBufLen, const std::string& msg) {
    if (!errBuf || errBufLen == 0) return;
    std::snprintf(errBuf, errBufLen, "%s", msg.c_str());
}

} // namespace

struct Asr4allContext {
    std::mutex mutex;
    std::string bundleDir;
    int nThreads = 4;

    // Mapped weights file (MUST outlive all Ort::Session instances)
    int weightsFd = -1;
    uint8_t* weightsMap = nullptr;
    size_t weightsSize = 0;
    Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::unordered_map<std::string, Ort::Value> sharedInitializers;

    // Loaded sessions (destroyed BEFORE sharedInitializers and weightsMap)
    std::unordered_map<std::string, std::unique_ptr<LoadedSession>> sessions;

    // Metadata
    std::unordered_map<std::string, std::string> graphFiles; // graph name -> filename
    std::vector<std::string> vocab;
    int64_t blankId = 256;
    int64_t samplesPerFrame = 640;
    std::string defaultTier;

    bool hasPcec = false;
    std::vector<std::string> pcecVocab;
    int64_t pcecBlankId = 6149;
    int64_t pcecCapId = 6144;
    int64_t pcecAllcapsId = 6145;
    int64_t pcecPeriodId = 6146;
    int64_t pcecCommaId = 6147;
    int64_t pcecQuestionId = 6148;
    int64_t pcecPadIn = 256;
    int64_t pcecPauseBlackout = 9;
    bool pcecRealPause = true;
    std::unordered_map<std::string, PcecRungMeta> pcecRungs;
    std::unordered_map<std::string, std::string> tierToRung;

    // Cached tier geometries populated as sessions load
    std::unordered_map<std::string, TierInfo> tierCache;

    // Cancellation support
    std::atomic<bool> aborted{false};
    Ort::RunOptions runOptions;

    ~Asr4allContext() {
        sessions.clear();
        sharedInitializers.clear();
        if (weightsMap != nullptr && weightsMap != MAP_FAILED) {
            munmap(weightsMap, weightsSize);
            weightsMap = nullptr;
        }
        if (weightsFd >= 0) {
            close(weightsFd);
            weightsFd = -1;
        }
    }

    LoadedSession& getOrLoadSession(const std::string& graphName) {
        auto it = sessions.find(graphName);
        if (it != sessions.end()) {
            return *it->second;
        }
        auto gIt = graphFiles.find(graphName);
        if (gIt == graphFiles.end()) {
            throw std::runtime_error("Graph not found in metadata.json: " + graphName);
        }
        if (!isSafeRelativeBundlePath(gIt->second)) {
            throw std::runtime_error("Unsafe graph path in metadata.json: " + gIt->second);
        }
        std::string graphPath = bundleDir + "/" + gIt->second;
        std::vector<uint8_t> modelBytes = readFileBytes(graphPath);
        std::vector<ExternalTensorSpec> extTensors = parseExternalTensors(modelBytes.data(), modelBytes.size());

        Ort::SessionOptions so;
        so.SetLogSeverityLevel(ORT_LOGGING_LEVEL_ERROR);
        so.DisableCpuMemArena();
        so.AddConfigEntry("session.disable_prepacking", "1");
        so.SetIntraOpNumThreads(std::max(1, nThreads));
        so.SetInterOpNumThreads(1);

        if (weightsMap != nullptr) {
            for (const auto& t : extTensors) {
                if (t.offset > weightsSize || t.length > weightsSize - t.offset) {
                    throw std::runtime_error("External tensor out of bounds for " + t.name);
                }
                std::string key = std::to_string(t.offset) + ":" + std::to_string(t.length) + ":" + std::to_string(t.onnxDtype);
                auto sIt = sharedInitializers.find(key);
                if (sIt == sharedInitializers.end()) {
                    Ort::Value val = Ort::Value::CreateTensor(
                        memInfo,
                        weightsMap + t.offset,
                        static_cast<size_t>(t.length),
                        t.dims.data(),
                        t.dims.size(),
                        mapOnnxDtype(t.onnxDtype)
                    );
                    sIt = sharedInitializers.emplace(std::move(key), std::move(val)).first;
                }
                so.AddInitializer(t.name.c_str(), sIt->second);
            }
        }

        auto loaded = std::make_unique<LoadedSession>();
        loaded->session = std::make_unique<Ort::Session>(sharedOrtEnv(), modelBytes.data(), modelBytes.size(), so);

        Ort::AllocatorWithDefaultOptions alloc;
        size_t nIn = loaded->session->GetInputCount();
        for (size_t i = 0; i < nIn; ++i) {
            TensorDesc d;
            auto namePtr = loaded->session->GetInputNameAllocated(i, alloc);
            d.name = namePtr.get();
            auto typeInfo = loaded->session->GetInputTypeInfo(i);
            auto tensorInfo = typeInfo.GetTensorTypeAndShapeInfo();
            d.elemType = tensorInfo.GetElementType();
            d.shape = tensorInfo.GetShape();
            loaded->inputByName[d.name] = i;
            loaded->inputs.push_back(std::move(d));
        }

        size_t nOut = loaded->session->GetOutputCount();
        for (size_t i = 0; i < nOut; ++i) {
            TensorDesc d;
            auto namePtr = loaded->session->GetOutputNameAllocated(i, alloc);
            d.name = namePtr.get();
            auto typeInfo = loaded->session->GetOutputTypeInfo(i);
            auto tensorInfo = typeInfo.GetTensorTypeAndShapeInfo();
            d.elemType = tensorInfo.GetElementType();
            d.shape = tensorInfo.GetShape();
            loaded->outputByName[d.name] = i;
            loaded->outputs.push_back(std::move(d));
        }

        LoadedSession& ref = *loaded;
        sessions.emplace(graphName, std::move(loaded));
        return ref;
    }

    const TierInfo& getTierInfo(const std::string& tierName) {
        auto it = tierCache.find(tierName);
        if (it != tierCache.end()) return it->second;

        LoadedSession& sess = getOrLoadSession(tierName);
        TierInfo info;
        info.name = tierName;
        auto pcmIt = sess.inputByName.find(tierName + "_pcm");
        if (pcmIt == sess.inputByName.end()) {
            throw std::runtime_error("Missing PCM input in graph " + tierName);
        }
        info.windowSamples = sess.inputs[pcmIt->second].shape.back();

        auto lpIt = sess.outputByName.find(tierName + "_log_probs");
        if (lpIt == sess.outputByName.end()) {
            throw std::runtime_error("Missing log_probs output in graph " + tierName);
        }
        info.commitFrames = sess.outputs[lpIt->second].shape.at(1);
        info.lookaheadFrames = (info.windowSamples / samplesPerFrame) - info.commitFrames;

        auto hidIt = sess.outputByName.find(tierName + "_hidden");
        if (hidIt != sess.outputByName.end()) {
            info.hasHidden = true;
            info.hiddenDim = sess.outputs[hidIt->second].shape.back();
        }

        auto rungIt = tierToRung.find(tierName);
        if (rungIt != tierToRung.end()) {
            info.pcecRungKey = rungIt->second;
        }

        auto inserted = tierCache.emplace(tierName, std::move(info)).first;
        return inserted->second;
    }
};

namespace {

std::vector<int64_t> extractInt64Values(const Ort::Value& v) {
    auto info = v.GetTensorTypeAndShapeInfo();
    size_t count = info.GetElementCount();
    ONNXTensorElementDataType dt = info.GetElementType();
    std::vector<int64_t> out(count);
    if (dt == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
        const int64_t* ptr = v.GetTensorData<int64_t>();
        std::copy(ptr, ptr + count, out.begin());
    } else if (dt == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) {
        const int32_t* ptr = v.GetTensorData<int32_t>();
        for (size_t i = 0; i < count; ++i) out[i] = ptr[i];
    } else {
        throw std::runtime_error("Unexpected integer tensor dtype in PCEC slots");
    }
    return out;
}

std::string renderPcecSlots(const Asr4allContext& ctx, const std::vector<int64_t>& slots) {
    struct Word {
        std::string text;
        std::string casing;
        std::string punct;
    };
    std::vector<Word> words;
    std::string pending;
    int64_t prev = -1;

    for (int64_t id : slots) {
        if (id == prev || id == ctx.pcecBlankId) {
            prev = id;
            continue;
        }
        prev = id;
        if (id == ctx.pcecCapId) {
            pending = "cap";
        } else if (id == ctx.pcecAllcapsId) {
            pending = "upper";
        } else if (id == ctx.pcecPeriodId) {
            if (!words.empty()) words.back().punct = ".";
        } else if (id == ctx.pcecCommaId) {
            if (!words.empty()) words.back().punct = ",";
        } else if (id == ctx.pcecQuestionId) {
            if (!words.empty()) words.back().punct = "?";
        } else if (id >= 0 && static_cast<size_t>(id) < ctx.pcecVocab.size()) {
            const std::string& tok = ctx.pcecVocab[static_cast<size_t>(id)];
            if (!tok.empty()) {
                if (tok[0] == ' ' || words.empty()) {
                    words.push_back(Word{tok, pending, ""});
                    pending.clear();
                } else {
                    words.back().text += tok;
                }
            }
        }
    }

    std::string result;
    bool sentenceStart = true;
    for (const auto& w : words) {
        std::string clean = trimAscii(w.text);
        if (clean.empty()) continue;
        if (w.casing == "upper") {
            clean = toUpperAscii(clean);
        } else if (w.casing == "cap" || sentenceStart) {
            clean = capFirstAscii(clean);
        }
        sentenceStart = (w.punct == "." || w.punct == "?");
        if (!result.empty()) result.push_back(' ');
        result += clean;
        result += w.punct;
    }
    return result;
}

void copyOrtValueToBuffer(const Ort::Value& src, TensorBuffer& dst) {
    auto info = src.GetTensorTypeAndShapeInfo();
    dst.shape = info.GetShape();
    dst.elemType = info.GetElementType();
    size_t bytes = info.GetElementCount();
    if (dst.elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 || dst.elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE) {
        bytes *= 8;
    } else if (dst.elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
        bytes *= 2;
    } else if (dst.elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL) {
        bytes *= 1;
    } else {
        bytes *= 4;
    }
    dst.raw.resize(bytes);
    if (bytes > 0) {
        std::memcpy(dst.raw.data(), src.GetTensorRawData(), bytes);
    }
}

struct PcecState {
    const Asr4allContext& ctx;
    LoadedSession& pcecSess;
    LoadedSession& flushSess;
    std::string pName;
    int64_t commit = 0;
    int64_t lookahead = 0;
    int64_t hiddenDim = 0;
    bool wantsAcoustic = false;
    bool wantsKeep = false;

    TensorBuffer stateBuf;
    TensorBuffer seenBuf;

    std::vector<int64_t> ids;
    std::vector<int64_t> pause;
    std::vector<float> acoustic; // flattened [tokens * hiddenDim]
    std::vector<int64_t> slots;
    int64_t consumed = 0;

    bool hasOpen = false;
    int64_t openTok = 0;
    std::vector<double> openAcc;
    int64_t openCount = 0;
    int openBlanks = 0;
    int blanks = 0;
    int64_t prevFid = -1;

    PcecState(Asr4allContext& context, const PcecRungMeta& rung, int64_t dim)
        : ctx(context),
          pcecSess(context.getOrLoadSession(rung.name)),
          flushSess(context.getOrLoadSession(rung.flushName)),
          pName(rung.name),
          hiddenDim(dim) {
        const auto& hypDesc = pcecSess.inputs.at(pcecSess.inputByName.at(pName + "_hyp_ids"));
        commit = hypDesc.shape.at(1);
        const auto& tailDesc = flushSess.outputs.at(flushSess.outputByName.at(pName + "_tail_slots"));
        int64_t flushSlots = tailDesc.shape.at(1);
        lookahead = (flushSlots - 1) / 2 - commit;

        wantsAcoustic = pcecSess.inputByName.count(pName + "_acoustic") > 0;
        wantsKeep = pcecSess.inputByName.count(pName + "_keep") > 0;

        stateBuf = TensorBuffer::zeros(pcecSess.inputs.at(pcecSess.inputByName.at(pName + "_state")));
        seenBuf = TensorBuffer::zeros(pcecSess.inputs.at(pcecSess.inputByName.at(pName + "_seen")));
        openAcc.assign(static_cast<size_t>(std::max<int64_t>(0, hiddenDim)), 0.0);
    }

    void pool(const std::vector<int64_t>& frameIds, const float* hiddenPtr, size_t nFrames) {
        for (size_t t = 0; t < nFrames; ++t) {
            int64_t fid = frameIds[t];
            if (fid != prevFid && fid != ctx.blankId) {
                if (hasOpen) emit();
                hasOpen = true;
                openTok = fid;
                openCount = 1;
                openBlanks = blanks;
                blanks = 0;
                if (hiddenPtr != nullptr && hiddenDim > 0) {
                    const float* row = hiddenPtr + t * static_cast<size_t>(hiddenDim);
                    for (int64_t d = 0; d < hiddenDim; ++d) {
                        openAcc[static_cast<size_t>(d)] = static_cast<double>(row[d]);
                    }
                }
            } else if (hasOpen) {
                ++openCount;
                if (hiddenPtr != nullptr && hiddenDim > 0) {
                    const float* row = hiddenPtr + t * static_cast<size_t>(hiddenDim);
                    for (int64_t d = 0; d < hiddenDim; ++d) {
                        openAcc[static_cast<size_t>(d)] += static_cast<double>(row[d]);
                    }
                }
            }
            prevFid = fid;
            if (fid == ctx.blankId) {
                ++blanks;
            }
        }
    }

    void emit() {
        if (!hasOpen) return;
        hasOpen = false;
        ids.push_back(openTok);
        pause.push_back(pauseBucket(openBlanks));
        if (hiddenDim > 0) {
            double inv = 1.0 / static_cast<double>(std::max<int64_t>(1, openCount));
            size_t oldSz = acoustic.size();
            acoustic.resize(oldSz + static_cast<size_t>(hiddenDim));
            for (int64_t d = 0; d < hiddenDim; ++d) {
                acoustic[oldSz + static_cast<size_t>(d)] = static_cast<float>(openAcc[static_cast<size_t>(d)] * inv);
            }
        }
    }

    void flushOpen() {
        if (hasOpen) emit();
    }

    void drain(const Ort::MemoryInfo& memInfo, const Ort::RunOptions& runOpts) {
        size_t k = static_cast<size_t>(commit);
        while (ids.size() >= k) {
            std::vector<int64_t> hypIds(k, ctx.pcecPadIn);
            std::vector<int64_t> pauseArr(k, ctx.pcecPauseBlackout);
            std::vector<float> acArr(wantsAcoustic ? k * static_cast<size_t>(hiddenDim) : 0, 0.0f);
            std::vector<float> keepArr(wantsKeep ? k : 0, 0.0f);

            for (size_t i = 0; i < k; ++i) {
                hypIds[i] = ids[i];
                if (ctx.pcecRealPause) pauseArr[i] = pause[i];
                if (wantsAcoustic && hiddenDim > 0) {
                    std::copy(
                        acoustic.begin() + i * static_cast<size_t>(hiddenDim),
                        acoustic.begin() + (i + 1) * static_cast<size_t>(hiddenDim),
                        acArr.begin() + i * static_cast<size_t>(hiddenDim)
                    );
                }
            }

            std::vector<const char*> inNames;
            std::vector<Ort::Value> inVals;
            std::string hypName = pName + "_hyp_ids";
            std::string pauseName = pName + "_pause";
            std::string acName = pName + "_acoustic";
            std::string keepName = pName + "_keep";
            std::string stateName = pName + "_state";
            std::string seenName = pName + "_seen";

            int64_t k64 = commit;
            int64_t shape2d[2] = {1, k64};
            int64_t shape3d[3] = {1, k64, hiddenDim};

            inNames.push_back(hypName.c_str());
            inVals.push_back(Ort::Value::CreateTensor<int64_t>(memInfo, hypIds.data(), hypIds.size(), shape2d, 2));

            inNames.push_back(pauseName.c_str());
            inVals.push_back(Ort::Value::CreateTensor<int64_t>(memInfo, pauseArr.data(), pauseArr.size(), shape2d, 2));

            if (wantsAcoustic) {
                inNames.push_back(acName.c_str());
                inVals.push_back(Ort::Value::CreateTensor<float>(memInfo, acArr.data(), acArr.size(), shape3d, 3));
            }
            if (wantsKeep) {
                inNames.push_back(keepName.c_str());
                inVals.push_back(Ort::Value::CreateTensor<float>(memInfo, keepArr.data(), keepArr.size(), shape2d, 2));
            }
            inNames.push_back(stateName.c_str());
            inVals.push_back(stateBuf.asOrtValue(memInfo));
            inNames.push_back(seenName.c_str());
            inVals.push_back(seenBuf.asOrtValue(memInfo));

            std::string outSlotsName = pName + "_slots";
            std::string outStateName = pName + "_state_out";
            std::string outSeenName = pName + "_seen_out";
            const char* outNames[3] = {outSlotsName.c_str(), outStateName.c_str(), outSeenName.c_str()};

            auto outs = pcecSess.session->Run(runOpts, inNames.data(), inVals.data(), inNames.size(), outNames, 3);

            std::vector<int64_t> stepSlots = extractInt64Values(outs[0]);
            int64_t skip = std::min<int64_t>(2 * commit, std::max<int64_t>(0, 2 * lookahead - 2 * consumed));
            int64_t limit = std::min<int64_t>(2 * commit, static_cast<int64_t>(stepSlots.size()));
            for (int64_t i = skip; i < limit; ++i) {
                slots.push_back(stepSlots[static_cast<size_t>(i)]);
            }

            // Update caches
            copyOrtValueToBuffer(outs[1], stateBuf);
            copyOrtValueToBuffer(outs[2], seenBuf);

            ids.erase(ids.begin(), ids.begin() + k);
            pause.erase(pause.begin(), pause.begin() + k);
            if (wantsAcoustic && hiddenDim > 0) {
                acoustic.erase(acoustic.begin(), acoustic.begin() + k * static_cast<size_t>(hiddenDim));
            }
            consumed += commit;
        }
    }

    std::vector<int64_t> tail(const Ort::MemoryInfo& memInfo, const Ort::RunOptions& runOpts, bool includeOpenToken = false) const {
        size_t baseN = ids.size();
        size_t k = static_cast<size_t>(commit);
        bool appendOpen = includeOpenToken && hasOpen && baseN < k;
        size_t n = baseN + (appendOpen ? 1 : 0);

        std::vector<int64_t> hypIds(k, ctx.pcecPadIn);
        std::vector<int64_t> pauseArr(k, ctx.pcecPauseBlackout);
        std::vector<float> acArr(wantsAcoustic ? k * static_cast<size_t>(hiddenDim) : 0, 0.0f);
        std::vector<float> keepArr(wantsKeep ? k : 0, 0.0f);

        for (size_t i = 0; i < baseN; ++i) {
            hypIds[i] = ids[i];
            if (ctx.pcecRealPause) pauseArr[i] = pause[i];
            if (wantsAcoustic && hiddenDim > 0) {
                std::copy(
                    acoustic.begin() + i * static_cast<size_t>(hiddenDim),
                    acoustic.begin() + (i + 1) * static_cast<size_t>(hiddenDim),
                    acArr.begin() + i * static_cast<size_t>(hiddenDim)
                );
            }
        }
        if (appendOpen) {
            hypIds[baseN] = openTok;
            if (ctx.pcecRealPause) pauseArr[baseN] = pauseBucket(openBlanks);
            if (wantsAcoustic && hiddenDim > 0) {
                double inv = 1.0 / static_cast<double>(std::max<int64_t>(1, openCount));
                for (int64_t d = 0; d < hiddenDim; ++d) {
                    acArr[baseN * static_cast<size_t>(hiddenDim) + static_cast<size_t>(d)] =
                        static_cast<float>(openAcc[static_cast<size_t>(d)] * inv);
                }
            }
        }

        std::vector<const char*> inNames;
        std::vector<Ort::Value> inVals;
        std::string hypName = pName + "_hyp_ids";
        std::string pauseName = pName + "_pause";
        std::string acName = pName + "_acoustic";
        std::string keepName = pName + "_keep";
        std::string stateName = pName + "_state";
        std::string seenName = pName + "_seen";
        std::string nRealName = pName + "_n_real";

        int64_t k64 = commit;
        int64_t shape2d[2] = {1, k64};
        int64_t shape3d[3] = {1, k64, hiddenDim};
        int64_t nRealVal = static_cast<int64_t>(n);

        inNames.push_back(hypName.c_str());
        inVals.push_back(Ort::Value::CreateTensor<int64_t>(memInfo, hypIds.data(), hypIds.size(), shape2d, 2));

        inNames.push_back(pauseName.c_str());
        inVals.push_back(Ort::Value::CreateTensor<int64_t>(memInfo, pauseArr.data(), pauseArr.size(), shape2d, 2));

        if (wantsAcoustic) {
            inNames.push_back(acName.c_str());
            inVals.push_back(Ort::Value::CreateTensor<float>(memInfo, acArr.data(), acArr.size(), shape3d, 3));
        }
        if (wantsKeep) {
            inNames.push_back(keepName.c_str());
            inVals.push_back(Ort::Value::CreateTensor<float>(memInfo, keepArr.data(), keepArr.size(), shape2d, 2));
        }
        TensorBuffer stateCopy = stateBuf;
        TensorBuffer seenCopy = seenBuf;
        inNames.push_back(stateName.c_str());
        inVals.push_back(stateCopy.asOrtValue(memInfo));
        inNames.push_back(seenName.c_str());
        inVals.push_back(seenCopy.asOrtValue(memInfo));

        // Read n_real shape from flush session (scalar [] or [1])
        const auto& nRealDesc = flushSess.inputs.at(flushSess.inputByName.at(nRealName));
        inNames.push_back(nRealName.c_str());
        inVals.push_back(Ort::Value::CreateTensor<int64_t>(
            memInfo, &nRealVal, 1, nRealDesc.shape.data(), nRealDesc.shape.size()
        ));

        std::string outTailName = pName + "_tail_slots";
        const char* outNames[1] = {outTailName.c_str()};
        auto outs = flushSess.session->Run(runOpts, inNames.data(), inVals.data(), inNames.size(), outNames, 1);

        std::vector<int64_t> tailSlots = extractInt64Values(outs[0]);
        int64_t valid = 2 * lookahead + 2 * static_cast<int64_t>(n) + 1;
        int64_t skip = std::max<int64_t>(0, 2 * lookahead - 2 * consumed);
        int64_t end = std::min<int64_t>(valid, static_cast<int64_t>(tailSlots.size()));
        std::vector<int64_t> result;
        for (int64_t i = skip; i < end; ++i) {
            result.push_back(tailSlots[static_cast<size_t>(i)]);
        }
        return result;
    }

    std::string renderPreview(const Ort::MemoryInfo& memInfo, const Ort::RunOptions& runOpts) const {
        if (slots.empty() && ids.empty() && !hasOpen) {
            return "";
        }
        std::vector<int64_t> previewSlots = slots;
        if (!ids.empty() || hasOpen) {
            std::vector<int64_t> tailSlots = tail(memInfo, runOpts, /*includeOpenToken=*/true);
            previewSlots.insert(previewSlots.end(), tailSlots.begin(), tailSlots.end());
        }
        return renderPcecSlots(ctx, previewSlots);
    }
};

std::string collapseCtcPlain(const Asr4allContext& ctx, const std::vector<int64_t>& ids) {
    std::string raw;
    int64_t prev = -1;
    for (int64_t id : ids) {
        if (id != prev && id != ctx.blankId && id >= 0 && static_cast<size_t>(id) < ctx.vocab.size()) {
            raw += ctx.vocab[static_cast<size_t>(id)];
        }
        prev = id;
    }
    // Collapse runs of ASCII whitespace to single spaces and trim
    std::string collapsed;
    bool inSpace = true;
    for (char c : raw) {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (!inSpace) {
                collapsed.push_back(' ');
                inSpace = true;
            }
        } else {
            collapsed.push_back(c);
            inSpace = false;
        }
    }
    if (!collapsed.empty() && collapsed.back() == ' ') {
        collapsed.pop_back();
    }
    return collapsed;
}

} // namespace

extern "C" {

Asr4allContext* asr4all_init(const char* bundle_dir, int n_threads, char* err_buf, size_t err_buf_len) {
    if (!bundle_dir || !*bundle_dir) {
        writeErr(err_buf, err_buf_len, "bundle_dir is empty");
        return nullptr;
    }
    try {
        auto ctx = std::make_unique<Asr4allContext>();
        ctx->bundleDir = bundle_dir;
        ctx->nThreads = std::max(1, n_threads);

        std::string metaPath = ctx->bundleDir + "/metadata.json";
        std::string metaStr = readFileString(metaPath);
        JsonValue meta = JsonParser(metaStr).parse();

        ctx->blankId = meta.get("blank_id") ? meta.get("blank_id")->asInt(256) : 256;
        ctx->defaultTier = meta.get("default_tier") ? meta.get("default_tier")->asString("stream_c16r4") : "stream_c16r4";

        if (const JsonValue* streaming = meta.get("streaming")) {
            if (const JsonValue* spf = streaming->get("samples_per_frame")) {
                ctx->samplesPerFrame = std::max<int64_t>(1, spf->asInt(640));
            }
        }

        if (const JsonValue* vocabArr = meta.get("vocab"); vocabArr && vocabArr->isArray()) {
            ctx->vocab.reserve(vocabArr->arrVal.size());
            for (const auto& item : vocabArr->arrVal) {
                ctx->vocab.push_back(item.asString());
            }
        }

        if (const JsonValue* graphs = meta.get("graphs"); graphs && graphs->isObject()) {
            for (const auto& kv : graphs->objVal) {
                std::string rel = kv.second.asString();
                if (!isSafeRelativeBundlePath(rel)) {
                    throw std::runtime_error("Unsafe graph filename in metadata.json: " + rel);
                }
                ctx->graphFiles[kv.first] = std::move(rel);
            }
        }

        if (const JsonValue* pcec = meta.get("pcec"); pcec && pcec->isObject()) {
            ctx->hasPcec = true;
            if (const JsonValue* pv = pcec->get("vocab"); pv && pv->isArray()) {
                ctx->pcecVocab.reserve(pv->arrVal.size());
                for (const auto& item : pv->arrVal) {
                    ctx->pcecVocab.push_back(item.asString());
                }
            }
            if (const JsonValue* b = pcec->get("blank_id")) ctx->pcecBlankId = b->asInt(6149);
            if (const JsonValue* p = pcec->get("pad_in")) ctx->pcecPadIn = p->asInt(256);
            if (const JsonValue* pb = pcec->get("pause_blackout")) ctx->pcecPauseBlackout = pb->asInt(9);
            if (const JsonValue* rp = pcec->get("real_pause")) ctx->pcecRealPause = rp->asBool(true);
            if (const JsonValue* ctrl = pcec->get("ctrl"); ctrl && ctrl->isObject()) {
                if (const JsonValue* c = ctrl->get("cap")) ctx->pcecCapId = c->asInt(6144);
                if (const JsonValue* c = ctrl->get("allcaps")) ctx->pcecAllcapsId = c->asInt(6145);
                if (const JsonValue* c = ctrl->get("period")) ctx->pcecPeriodId = c->asInt(6146);
                if (const JsonValue* c = ctrl->get("comma")) ctx->pcecCommaId = c->asInt(6147);
                if (const JsonValue* c = ctrl->get("question")) ctx->pcecQuestionId = c->asInt(6148);
            }
            if (const JsonValue* rungs = pcec->get("rungs"); rungs && rungs->isObject()) {
                for (const auto& kv : rungs->objVal) {
                    PcecRungMeta r;
                    if (const JsonValue* n = kv.second.get("name")) r.name = n->asString();
                    if (const JsonValue* f = kv.second.get("flush")) r.flushName = f->asString();
                    ctx->pcecRungs[kv.first] = std::move(r);
                }
            }
            if (const JsonValue* tr = pcec->get("tier_rung"); tr && tr->isObject()) {
                for (const auto& kv : tr->objVal) {
                    if (kv.second.isString()) {
                        ctx->tierToRung[kv.first] = kv.second.asString();
                    } else {
                        ctx->tierToRung[kv.first] = std::to_string(kv.second.asInt());
                    }
                }
            }
        }

        if (const JsonValue* weights = meta.get("weights"); weights && weights->isString()) {
            std::string relWeights = weights->asString();
            if (!isSafeRelativeBundlePath(relWeights)) {
                throw std::runtime_error("Unsafe weights filename in metadata.json: " + relWeights);
            }
            std::string weightsPath = ctx->bundleDir + "/" + relWeights;
            int fd = open(weightsPath.c_str(), O_RDONLY);
            if (fd < 0) {
                throw std::runtime_error("Failed to open weights file: " + weightsPath + " (" + std::strerror(errno) + ")");
            }
            struct stat st{};
            if (fstat(fd, &st) != 0 || st.st_size <= 0) {
                close(fd);
                throw std::runtime_error("Failed to stat weights file: " + weightsPath);
            }
            void* mapped = mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
            if (mapped == MAP_FAILED) {
                close(fd);
                throw std::runtime_error("mmap failed for weights file: " + weightsPath);
            }
            ctx->weightsFd = fd;
            ctx->weightsMap = static_cast<uint8_t*>(mapped);
            ctx->weightsSize = static_cast<size_t>(st.st_size);
        }

        return ctx.release();
    } catch (const std::exception& e) {
        writeErr(err_buf, err_buf_len, e.what());
        return nullptr;
    }
}

void asr4all_free(Asr4allContext* ctx) {
    delete ctx;
}

void asr4all_abort(Asr4allContext* ctx) {
    if (!ctx) return;
    ctx->aborted.store(true, std::memory_order_release);
    try {
        ctx->runOptions.SetTerminate();
    } catch (...) {
    }
}

void asr4all_reset_abort(Asr4allContext* ctx) {
    if (!ctx) return;
    ctx->aborted.store(false, std::memory_order_release);
    try {
        ctx->runOptions.UnsetTerminate();
    } catch (...) {
    }
}

} // extern "C"

struct Asr4allStream {
    Asr4allContext* ctx = nullptr;
    TierInfo tier;
    LoadedSession* streamSess = nullptr;
    TensorBuffer filterCache;
    TensorBuffer attnCache;
    std::unique_ptr<PcecState> pcec;
    std::vector<float> pendingPcm;
    std::vector<int64_t> allIds;
    std::vector<float> win;
    std::string pcmName;
    std::string lpOutName;
    std::string fcOutName;
    std::string acOutName;
    std::string hidOutName;
    std::string lastPreview;
    bool finished = false;

    Asr4allStream(Asr4allContext* context, const std::string& selectedTier, bool applyPcec)
        : ctx(context),
          tier(context->getTierInfo(selectedTier)),
          streamSess(&context->getOrLoadSession(tier.name)) {
        const auto& filterDesc = streamSess->inputs.at(streamSess->inputByName.at("filter_cache"));
        const auto& attnDesc = streamSess->inputs.at(streamSess->inputByName.at("attn_cache"));
        filterCache = TensorBuffer::zeros(filterDesc);
        attnCache = TensorBuffer::zeros(attnDesc);

        if (applyPcec && ctx->hasPcec && tier.hasHidden && !tier.pcecRungKey.empty()) {
            auto rIt = ctx->pcecRungs.find(tier.pcecRungKey);
            if (rIt != ctx->pcecRungs.end()) {
                pcec = std::make_unique<PcecState>(*ctx, rIt->second, tier.hiddenDim);
            }
        }

        win.assign(static_cast<size_t>(tier.windowSamples), 0.0f);
        pcmName = tier.name + "_pcm";
        lpOutName = tier.name + "_log_probs";
        fcOutName = tier.name + "_filter_cache_out";
        acOutName = tier.name + "_attn_cache_out";
        hidOutName = tier.name + "_hidden";
    }

    void runChunk(const float* windowPtr, size_t validFrames) {
        int64_t winShape[2] = {1, tier.windowSamples};
        const char* inNames[3] = {pcmName.c_str(), "filter_cache", "attn_cache"};
        Ort::Value inVals[3] = {
            Ort::Value::CreateTensor<float>(ctx->memInfo, const_cast<float*>(windowPtr), static_cast<size_t>(tier.windowSamples), winShape, 2),
            filterCache.asOrtValue(ctx->memInfo),
            attnCache.asOrtValue(ctx->memInfo)
        };

        std::vector<const char*> outNames = {lpOutName.c_str(), fcOutName.c_str(), acOutName.c_str()};
        if (pcec) {
            outNames.push_back(hidOutName.c_str());
        }

        auto outs = streamSess->session->Run(
            ctx->runOptions,
            inNames,
            inVals,
            3,
            outNames.data(),
            outNames.size()
        );

        copyOrtValueToBuffer(outs[1], filterCache);
        copyOrtValueToBuffer(outs[2], attnCache);

        auto lpInfo = outs[0].GetTensorTypeAndShapeInfo();
        auto lpShape = lpInfo.GetShape();
        size_t vocabSize = static_cast<size_t>(lpShape.at(2));
        const float* lpData = outs[0].GetTensorData<float>();

        std::vector<int64_t> chunkIds(validFrames);
        for (size_t f = 0; f < validFrames; ++f) {
            const float* row = lpData + f * vocabSize;
            size_t bestIdx = 0;
            float bestVal = row[0];
            for (size_t v = 1; v < vocabSize; ++v) {
                if (row[v] > bestVal) {
                    bestVal = row[v];
                    bestIdx = v;
                }
            }
            chunkIds[f] = static_cast<int64_t>(bestIdx);
        }

        if (pcec && outs.size() > 3 && validFrames > 0) {
            const float* hidData = outs[3].GetTensorData<float>();
            pcec->pool(chunkIds, hidData, validFrames);
            pcec->drain(ctx->memInfo, ctx->runOptions);
        } else {
            allIds.insert(allIds.end(), chunkIds.begin(), chunkIds.end());
        }
    }

    bool feed(const float* samples, size_t nSamples) {
        if (samples && nSamples > 0) {
            pendingPcm.insert(pendingPcm.end(), samples, samples + nSamples);
        }
        bool ranChunk = false;
        size_t winSamples = static_cast<size_t>(tier.windowSamples);
        size_t commitSamples = static_cast<size_t>(tier.commitFrames) * static_cast<size_t>(ctx->samplesPerFrame);
        size_t offset = 0;

        // Drop samples whose chunk already advanced the caches on every exit path (normal, abort, or a throw
        // from a later runChunk), so a resumed stream never re-feeds audio into already-updated state.
        auto consume = [&]() {
            if (offset > 0) {
                pendingPcm.erase(pendingPcm.begin(), pendingPcm.begin() + static_cast<std::ptrdiff_t>(offset));
                offset = 0;
            }
        };
        try {
            while (pendingPcm.size() - offset >= winSamples) {
                if (ctx->aborted.load(std::memory_order_acquire)) {
                    break;
                }
                runChunk(pendingPcm.data() + offset, static_cast<size_t>(tier.commitFrames));
                offset += commitSamples;
                ranChunk = true;
            }
        } catch (...) {
            consume();
            throw;
        }
        consume();
        return ranChunk;
    }

    std::string currentPreview() {
        if (pcec) {
            lastPreview = pcec->renderPreview(ctx->memInfo, ctx->runOptions);
        } else {
            lastPreview = collapseCtcPlain(*ctx, allIds);
        }
        return lastPreview;
    }

    std::string finish() {
        if (finished) return lastPreview;
        finished = true;

        if (!pendingPcm.empty()) {
            size_t spf = static_cast<size_t>(ctx->samplesPerFrame);
            size_t paddedLen = ((pendingPcm.size() + spf - 1) / spf) * spf;
            if (paddedLen > pendingPcm.size()) {
                pendingPcm.resize(paddedLen, 0.0f);
            }
            size_t totalFrames = paddedLen / spf;
            size_t commitFrames = static_cast<size_t>(tier.commitFrames);
            size_t commitSamples = commitFrames * spf;
            size_t offset = 0;

            while (offset < paddedLen) {
                if (ctx->aborted.load(std::memory_order_acquire)) {
                    return "";
                }
                std::fill(win.begin(), win.end(), 0.0f);
                size_t copyCount = std::min(win.size(), paddedLen - offset);
                std::memcpy(win.data(), pendingPcm.data() + offset, copyCount * sizeof(float));
                size_t remFrames = totalFrames - (offset / spf);
                size_t valid = std::min(commitFrames, remFrames);
                runChunk(win.data(), valid);
                offset += commitSamples;
            }
            pendingPcm.clear();
        }

        if (ctx->aborted.load(std::memory_order_acquire)) {
            return "";
        }

        if (pcec) {
            pcec->flushOpen();
            pcec->drain(ctx->memInfo, ctx->runOptions);
            std::vector<int64_t> allSlots = std::move(pcec->slots);
            std::vector<int64_t> tailSlots = pcec->tail(ctx->memInfo, ctx->runOptions, /*includeOpenToken=*/false);
            allSlots.insert(allSlots.end(), tailSlots.begin(), tailSlots.end());
            lastPreview = renderPcecSlots(*ctx, allSlots);
        } else {
            lastPreview = collapseCtcPlain(*ctx, allIds);
        }
        return lastPreview;
    }
};

namespace {
int allocateOutText(const std::string& text, char** out_text, char* err_buf, size_t err_buf_len) {
    char* dup = static_cast<char*>(std::malloc(text.size() + 1));
    if (!dup) {
        writeErr(err_buf, err_buf_len, "Out of memory allocating transcript string");
        return -1;
    }
    std::memcpy(dup, text.c_str(), text.size() + 1);
    *out_text = dup;
    return 0;
}
} // namespace

extern "C" {

void asr4all_atomic_store_i32(int32_t* target, int32_t value) {
    if (!target) return;
    __atomic_store_n(target, value, __ATOMIC_SEQ_CST);
}

int32_t asr4all_atomic_load_i32(const int32_t* target) {
    if (!target) return 0;
    return __atomic_load_n(target, __ATOMIC_SEQ_CST);
}

Asr4allStream* asr4all_stream_begin(
    Asr4allContext* ctx,
    const char* tier_name,
    bool apply_pcec,
    char* err_buf,
    size_t err_buf_len
) {
    if (!ctx) {
        writeErr(err_buf, err_buf_len, "Invalid context in asr4all_stream_begin");
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(ctx->mutex);
    if (ctx->aborted.load(std::memory_order_acquire)) {
        writeErr(err_buf, err_buf_len, "Transcription aborted");
        return nullptr;
    }
    try {
        std::string selectedTier = (tier_name && *tier_name) ? std::string(tier_name) : ctx->defaultTier;
        return new Asr4allStream(ctx, selectedTier, apply_pcec);
    } catch (const std::exception& e) {
        writeErr(err_buf, err_buf_len, e.what());
        return nullptr;
    }
}

int asr4all_stream_step(
    Asr4allStream* stream,
    const float* new_samples,
    size_t n_samples,
    char** out_text,
    int* out_window_samples,
    char* err_buf,
    size_t err_buf_len
) {
    if (!stream || !stream->ctx || !out_text) {
        writeErr(err_buf, err_buf_len, "Invalid argument to asr4all_stream_step");
        return -1;
    }
    *out_text = nullptr;
    Asr4allContext* ctx = stream->ctx;
    std::lock_guard<std::mutex> lock(ctx->mutex);
    if (ctx->aborted.load(std::memory_order_acquire)) {
        return -2;
    }
    if (out_window_samples) {
        *out_window_samples = static_cast<int>(stream->tier.windowSamples);
    }
    try {
        bool ran = stream->feed(new_samples, n_samples);
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        const std::string& text = ran ? stream->currentPreview() : stream->lastPreview;
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        return allocateOutText(text, out_text, err_buf, err_buf_len);
    } catch (const std::exception& e) {
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        writeErr(err_buf, err_buf_len, e.what());
        return -1;
    }
}

int asr4all_stream_finish(
    Asr4allStream* stream,
    char** out_text,
    int* out_window_samples,
    char* err_buf,
    size_t err_buf_len
) {
    if (!stream || !stream->ctx || !out_text) {
        writeErr(err_buf, err_buf_len, "Invalid argument to asr4all_stream_finish");
        return -1;
    }
    *out_text = nullptr;
    Asr4allContext* ctx = stream->ctx;
    std::lock_guard<std::mutex> lock(ctx->mutex);
    if (ctx->aborted.load(std::memory_order_acquire)) {
        return -2;
    }
    if (out_window_samples) {
        *out_window_samples = static_cast<int>(stream->tier.windowSamples);
    }
    try {
        std::string finalText = stream->finish();
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        return allocateOutText(finalText, out_text, err_buf, err_buf_len);
    } catch (const std::exception& e) {
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        writeErr(err_buf, err_buf_len, e.what());
        return -1;
    }
}

void asr4all_stream_free(Asr4allStream* stream) {
    delete stream;
}

int asr4all_transcribe(
    Asr4allContext* ctx,
    const float* samples,
    size_t n_samples,
    const char* tier_name,
    bool apply_pcec,
    char** out_text,
    int* out_window_samples,
    char* err_buf,
    size_t err_buf_len
) {
    if (!ctx || !out_text) {
        writeErr(err_buf, err_buf_len, "Invalid argument to asr4all_transcribe");
        return -1;
    }
    *out_text = nullptr;
    if (!samples || n_samples == 0) {
        writeErr(err_buf, err_buf_len, "Empty audio samples");
        return -1;
    }

    std::lock_guard<std::mutex> lock(ctx->mutex);
    if (ctx->aborted.load(std::memory_order_acquire)) {
        return -2;
    }

    try {
        std::string selectedTier = (tier_name && *tier_name) ? std::string(tier_name) : ctx->defaultTier;
        Asr4allStream stream(ctx, selectedTier, apply_pcec);
        if (out_window_samples) {
            *out_window_samples = static_cast<int>(stream.tier.windowSamples);
        }
        stream.feed(samples, n_samples);
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        std::string finalText = stream.finish();
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        return allocateOutText(finalText, out_text, err_buf, err_buf_len);
    } catch (const std::exception& e) {
        if (ctx->aborted.load(std::memory_order_acquire)) {
            return -2;
        }
        writeErr(err_buf, err_buf_len, e.what());
        return -1;
    }
}

void asr4all_free_string(char* str) {
    std::free(str);
}

} // extern "C"
