/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2023-2023. All rights reserved.
 * This tool is used to add GCC 9 and GCC 10 summary info into gcov file.
 */

#include <cstdio>
#include <string>
#include <vector>
#include <cassert>

using namespace std;

constexpr long long GCOV_DATA_MAGIC = 0x67636461u;
constexpr long long GCOV_TAG_FUNCTION = 0x01000000u;
constexpr long long GCOV_TAG_COUNTER_BASE = 0x01a10000u;
constexpr long long GCOV_TAG_OBJECT_SUMMARY = 0xa1000000u;

/* value profile counter */
constexpr long long GCOV_TAG_COUNTER_INTERVAL = 0x01a30000u;
constexpr long long GCOV_TAG_COUNTER_POW2 = 0x01a50000u;
constexpr long long GCOV_TAG_COUNTER_TOPN = 0x01a70000u;
constexpr long long GCOV_TAG_COUNTER_IC = 0x01a90000u; // indirect call profiler
constexpr long long GCOV_TAG_COUNTER_AVERAGE = 0x01ab0000u;
constexpr long long GCOV_TAG_COUNTER_IOR = 0x01ad0000u;
constexpr long long GCOV_TAG_COUNTER_TP = 0x01af0000u; // time profiler

static int ReadFile(const string filename, vector<char>& out)
{
    FILE* fp = fopen(filename.c_str(), "rb");
    if (!fp) {
        fprintf(stderr, "[!] Fail to read: %s\n", filename.c_str());
        return 1;
    }
    constexpr int bufSize = 4096;
    char buf[bufSize];
    size_t sz;
    while (sz = fread(buf, 1, bufSize, fp)) {
        out.insert(out.end(), buf, buf + sz);
    }
    fclose(fp);
    return 0;
}

static void SplitLines(const vector<char>& in, vector<string>& out)
{
    size_t pos = 0;
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] != '\r' && in[i] != '\n') {
            continue;
        }
        out.push_back(string(in.begin() + pos, in.begin() + i));
        if (in[i] == '\r' && i + 1 < in.size() && in[i + 1] == '\n') {
            i++;
        }
        pos = i + 1;
    }
    if (pos < in.size()) {
        out.push_back(string(in.begin() + pos, in.end()));
    }
}

static int WriteFile(string fileName, const vector<char> in, unsigned int valMax)
{
    if (in.size() < 12) {
        fprintf(stderr, "[!] Not enough size to write\n");
        return 1;
    }
    FILE* fp = fopen(fileName.c_str(), "wb");
    if (!fp) {
        fprintf(stderr, "[!] Fail to write: %s \n", fileName.c_str());
        return 1;
    }
    fwrite(in.data(), 1, 12, fp);
    unsigned int title[4] = {
        GCOV_TAG_OBJECT_SUMMARY,
        2,
        1,
        valMax
    };
    fwrite(title, 1, 16, fp);
    fwrite(in.data() + 12, 1, in.size() - 12, fp);
    fclose(fp);
    return 0;
}

static int ProcessFile(const string fileName)
{
    vector<char> source;
    if (ReadFile(fileName, source)) {
        fprintf(stderr, "[!] Fail to read file: %s \n", fileName.c_str());
        return 1;
    }
    int state = 1;
    unsigned int valMax = 0;
    unsigned int count = 0;
    unsigned int n = source.size() / 4;
    auto vData = (const unsigned int*) source.data();
    for (int i = 0; i < n; ++i) {
        unsigned int val = vData[i];
        switch (state) {
            case 1:
                if (val != GCOV_DATA_MAGIC) {
                    fprintf(stderr, "[!] GCOV_DATA_MAGIC mismatches: 0x%x\n", val);
                    return 1;
                }
                i += 2;
                state = 2;
                break;
            case 2:
                if (i == n - 1 && val) {
                    fprintf(stderr, "[!] Single last tag: 0x%x\n", val);
                    return 1;
                }
                if (val == GCOV_TAG_FUNCTION) {
                    i += 1 + vData[i + 1];
                } else if (val == GCOV_TAG_COUNTER_BASE) {
                    if (vData[i + 1] % 2) {
                        fprintf(stderr, "[!] Invalid length: %d\n", vData[i + 1]);
                        return 1;
                    }
                    count = vData[++i];
                    if (count) {
                        state = 3;
                    }
                } else if (val) {
                    switch (val) {
                        case GCOV_TAG_COUNTER_INTERVAL:
                        case GCOV_TAG_COUNTER_POW2:
                        case GCOV_TAG_COUNTER_TOPN:
                        case GCOV_TAG_COUNTER_IC:
                        case GCOV_TAG_COUNTER_AVERAGE:
                        case GCOV_TAG_COUNTER_IOR:
                        case GCOV_TAG_COUNTER_TP:
                            i += 1 + vData[i + 1];
                            break;
                        default:
                            fprintf(stderr, "[!] Unknown tag: 0x%x\n", val);
                            return 1;
                    }
                }
                break;
            case 3:
                valMax = valMax < val ? val : valMax;
                if (--count == 0) {
                    state = 2;
                }
                break;
            default:
                break;
        }
    }
    if (WriteFile(fileName, source, valMax)) {
        return 1;
    }
    return 0;
}

int main(int argc, char** argv)
{
    vector<char> fileNameList;
    if (argc != 2 || ReadFile(argv[1], fileNameList)) {
        fprintf(stderr, "USAGE:\n  %s <Input File List>\n", argv[0]);
        return 1;
    }
    vector<string> fileNames;
    SplitLines(fileNameList, fileNames);
    for (size_t i = 0; i < fileNames.size(); ++i) {
        string fileName = fileNames[i];
        fprintf(stderr, "[.] Processing %s \n", fileName.c_str());
        if (ProcessFile(fileName)) {
            return 1;
        }
    }
    fprintf(stderr, "[.] File procesed: %d \n", (int) fileNames.size());
    return 0;
}
