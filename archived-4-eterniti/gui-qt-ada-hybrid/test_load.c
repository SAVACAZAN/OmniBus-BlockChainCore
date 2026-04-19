#include <stdio.h>
#include <string.h>
#include <windows.h>

int pass = 0, fail = 0;
void check(const char* n, int c) { if(c){printf("  [PASS] %s\n",n);pass++;}else{printf("  [FAIL] %s\n",n);fail++;} }
void hexpr(const char* l, const unsigned char* d, int n) { printf("    %s: ",l); for(int i=0;i<n;i++)printf("%02x",d[i]); printf("\n"); }

int main(void) {
    printf("============================================================\n");
    printf("  OmniBus Ada SPARK DLL — Test Suite\n");
    printf("============================================================\n\n");

    HMODULE lib = LoadLibraryA("ada-vault/lib/libomnibus_vault.dll");
    if (!lib) { printf("FATAL: Cannot load DLL\n"); return 1; }
    printf("DLL loaded OK\n\n");

    /* Resolve */
    #define F(t,n) t p_##n = (t)GetProcAddress(lib, #n)
    typedef void(*fv)(void); typedef int(*fi)(void); typedef int(*fii)(int);
    typedef int(*fadd)(int,const char*,const char*,const char*,int);
    typedef int(*fdel)(int,int); typedef int(*fset)(int,int,int);
    typedef int(*fget)(int,int,char*,int,char*,int,int*,int*);
    typedef int(*fgsec)(int,int,char*,int);
    typedef int(*fmnem)(char*,int); typedef int(*fmval)(const char*);
    typedef int(*fsha)(const char*,int,char*,int);
    typedef void(*fwipe)(char*,int);
    typedef const char*(*fpath)(void);
    typedef int(*ftxaff)(int,int,int);
    typedef int(*ftxid)(const char*,int,char*,int);

    F(fv,vault_lib_init); F(fi,vault_init); F(fi,vault_lock);
    F(fi,vault_save); F(fi,vault_is_loaded);
    F(fadd,vault_add_key); F(fdel,vault_delete_key);
    F(fget,vault_get_key); F(fgsec,vault_get_secret);
    F(fset,vault_set_status); F(fii,vault_key_count);
    F(fii,vault_has_keys); F(fwipe,vault_wipe); F(fpath,vault_get_path);
    F(fmnem,mnemonic_generate_12); F(fmnem,mnemonic_generate_24);
    F(fmval,mnemonic_validate);
    F(fsha,sha256_hash); F(fsha,sha256_double);
    F(ftxaff,tx_can_afford); F(ftxid,tx_compute_txid);

    int rc;

    /* 1. VAULT */
    printf("--- 1. VAULT LIFECYCLE ---\n");
    if(p_vault_lib_init) p_vault_lib_init();
    rc = p_vault_init(); check("vault_init", rc==0);
    check("vault_is_loaded=1", p_vault_is_loaded()==1);
    printf("    Path: %s\n", p_vault_get_path());

    /* 2. KEYS */
    printf("\n--- 2. KEY MANAGEMENT ---\n");
    rc = p_vault_add_key(0,"TestKey1","ak_test123456789abc","secret_xyz",1);
    check("vault_add_key LCX", rc==0);
    rc = p_vault_add_key(1,"KrakenK","kr_abcdefghijklmno","kr_sec",0);
    check("vault_add_key Kraken", rc==0);
    check("key_count LCX=1", p_vault_key_count(0)==1);
    check("key_count Kraken=1", p_vault_key_count(1)==1);
    check("has_keys LCX=1", p_vault_has_keys(0)==1);
    check("has_keys Coinbase=0", p_vault_has_keys(2)==0);

    { char n[256]={0},k[256]={0}; int st=-1,iu=-1;
      rc = p_vault_get_key(0,0,n,256,k,256,&st,&iu);
      check("vault_get_key", rc==0);
      check("  in_use=1", iu==1);
      check("  status=Paid", st==1);
      check("  name=TestKey1", strcmp(n,"TestKey1")==0);
      printf("    name='%s' key='%s'\n",n,k);
    }
    { char s[256]={0};
      rc = p_vault_get_secret(0,0,s,256);
      check("vault_get_secret", rc==0);
      check("  secret=secret_xyz", strcmp(s,"secret_xyz")==0);
      p_vault_wipe(s,256);
      check("  wiped", s[0]==0);
    }
    rc = p_vault_set_status(0,0,2); check("set_status NotPaid", rc==0);
    rc = p_vault_delete_key(1,0); check("delete Kraken", rc==0);
    check("Kraken count=0", p_vault_key_count(1)==0);
    rc = p_vault_save(); check("vault_save", rc==0);
    rc = p_vault_lock(); check("vault_lock", rc==0);
    check("is_loaded=0", p_vault_is_loaded()==0);
    rc = p_vault_init(); check("vault_init reload", rc==0);
    check("LCX still 1", p_vault_key_count(0)==1);
    p_vault_delete_key(0,0); p_vault_save();

    /* 3. SHA-256 */
    printf("\n--- 3. SHA-256 ---\n");
    { unsigned char h[32]={0};
      rc = p_sha256_hash("",0,(char*)h,32);
      check("SHA256('')", rc==0);
      check("  [0]=0xe3", h[0]==0xe3);
      check("  [1]=0xb0", h[1]==0xb0);
      hexpr("hash",h,32);
      rc = p_sha256_hash("abc",3,(char*)h,32);
      check("SHA256('abc')", rc==0);
      check("  [0]=0xba", h[0]==0xba);
      hexpr("hash",h,32);
      /* Double SHA-256 */
      rc = p_sha256_double("abc",3,(char*)h,32);
      check("SHA256d('abc')", rc==0);
      hexpr("dbl",h,32);
    }

    /* 4. MNEMONIC */
    printf("\n--- 4. BIP-39 MNEMONIC ---\n");
    { char m12[256]={0}, m24[512]={0};
      rc = p_mnemonic_generate_12(m12,256);
      check("generate_12", rc==0);
      int wc=1; for(int i=0;m12[i];i++) if(m12[i]==' ') wc++;
      check("  12 words", wc==12);
      printf("    %s\n",m12);

      rc = p_mnemonic_generate_24(m24,512);
      check("generate_24", rc==0);
      wc=1; for(int i=0;m24[i];i++) if(m24[i]==' ') wc++;
      check("  24 words", wc==24);
      printf("    %.60s...\n",m24);

      rc = p_mnemonic_validate(m12);
      check("validate(12)", rc==1);
      rc = p_mnemonic_validate(m24);
      check("validate(24)", rc==1);
      rc = p_mnemonic_validate("bad words not valid here twelve");
      check("validate(garbage)=0", rc==0);
    }

    /* 5. TX ENGINE */
    printf("\n--- 5. TX ENGINE ---\n");
    check("afford(1000,500,100)=1", p_tx_can_afford(1000,500,100)==1);
    check("afford(1000,900,200)=0", p_tx_can_afford(1000,900,200)==0);
    check("afford(1000,1000,0)=1", p_tx_can_afford(1000,1000,0)==1);
    check("afford(0,1,0)=0", p_tx_can_afford(0,1,0)==0);
    { unsigned char d[10]={1,2,3,4,5,6,7,8,9,10}, txid[32]={0};
      rc = p_tx_compute_txid((char*)d,10,(char*)txid,32);
      check("tx_compute_txid", rc==0);
      int nz=0; for(int i=0;i<32;i++) if(txid[i]) nz++;
      check("  not all zeros", nz>5);
      hexpr("TXID",txid,32);
    }

    /* SUMMARY */
    printf("\n============================================================\n");
    printf("  RESULTS: %d passed, %d failed, %d total\n", pass, fail, pass+fail);
    printf("============================================================\n");

    FreeLibrary(lib);
    return fail>0 ? 1 : 0;
}
