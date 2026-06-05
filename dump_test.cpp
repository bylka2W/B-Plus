#include <cstdio>
#include <fstream>
#include <vector>
#include <cstdint>

int main() {
    std::ifstream f("C:\\B+ v1.0\\gen_x64\\test_dispatch6.exe", std::ios::binary | std::ios::ate);
    if (!f) { printf("Cannot open file\n"); return 1; }
    size_t size = f.tellg();
    f.seekg(0);
    std::vector<uint8_t> buf(size);
    f.read((char*)buf.data(), size);
    
    // Find .text section in PE
    auto dos = (uint32_t*)(buf.data());
    uint32_t pe_off = *(uint32_t*)(buf.data() + 0x3C);
    auto pe = buf.data() + pe_off;
    uint16_t num_sections = *(uint16_t*)(pe + 6);
    auto sections = pe + 0xF8; // after PE sig + file header + optional header
    
    for (int i = 0; i < num_sections; i++) {
        auto sec = sections + i * 40;
        char name[9] = {0};
        memcpy(name, sec, 8);
        uint32_t vaddr = *(uint32_t*)(sec + 12);
        uint32_t vsize = *(uint32_t*)(sec + 8);
        uint32_t raw_offset = *(uint32_t*)(sec + 20);
        uint32_t raw_size = *(uint32_t*)(sec + 16);
        
        printf("Section %s: VA=0x%x, Size=%u, RawOffset=0x%x, RawSize=%u\n", 
               name, vaddr, vsize, raw_offset, raw_size);
        
        if (strcmp(name, ".text") == 0) {
            printf("\n=== .text section (%u bytes) ===\n", raw_size);
            for (uint32_t j = 0; j < raw_size && j < 500; j++) {
                printf("%02x ", buf[raw_offset + j]);
                if ((j + 1) % 16 == 0) printf("\n");
            }
            printf("\n");
        }
    }
    return 0;
}
