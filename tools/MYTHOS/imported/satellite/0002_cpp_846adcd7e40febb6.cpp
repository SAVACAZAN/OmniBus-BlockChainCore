CheckBlock(fuzzBlock, state, Params().GetConsensus());
        } catch (...) {
            // Input invalid
        }
    }
};

// Main pentru testare
int main(int argc, char *argv[]) {