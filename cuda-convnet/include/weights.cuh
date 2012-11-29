/* 
 * Copyright (c) 2011, Alex Krizhevsky (akrizhevsky@gmail.com)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * 
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef WEIGHTS_CUH
#define	WEIGHTS_CUH

#include <string>
#include <vector>
#include <iostream>
#include <cutil_inline.h>
#include <assert.h>
#include <nvmatrix.cuh>
#include <matrix.h>
#include <pthread.h>
#include "util.cuh"

using namespace std;

class FuncThread;
class OutgoingWeights;
class IncomingWeights;

//struct WeightCombiner {
//    double decay;
//    double momentum;
//    double learningRate;
//
//    WeightCombiner(double momentum, double decay, double learningRate) :
//                    momentum(momentum), decay(decay), learningRate(learningRate) {
//    }
//
//    // Called when a new gradient is received (from the local or a remote machine).
//    // The default behavior is to add gradients into the accumulator vector.
//    virtual void combine(Matrix& gradient, Matrix& target) {
//        target.add(gradient);
//    }
//
//    // Merge an accumulated set of gradients into our weight vector.
//    virtual void apply(NVMatrix& weights, NVMatrix& grads) {
//        if (decay > 0) {
//            grads.add(weights, -decay * learningRate);
//        }
//
//        weights.add(grads);
//    }
//};

// Information about incoming/outgoing weight changes for a single layer.
struct WeightData {
    pthread_mutex_t sendMutex;
    pthread_mutex_t recvMutex;

    // NVMatrix inc;
    Matrix inc;
    bool incReady;
    int incCount;

    Matrix recvTmp;
    OutgoingWeights* outgoing;
    IncomingWeights* incoming;

    int64_t id;

    WeightData(int64_t id, int numRows, int numCols);

    bool handleRecv();
    bool handleSend();
};

typedef std::vector<WeightData*> WeightMap;

// Track incoming weight updates from remote machines.  Each Weight instance acquires a unique, consistent
// identifier via newId() at creation time.  sendUpdate should be called for each new weight delta created.
//
// Apply adds all current deltas to the given weight vector and resets the weight vector.
class NetworkManager {
private:
    static NetworkManager* _instance;
    NetworkManager();

    WeightMap _weights;

    int _cudaDevice;

    void _mpiThreadFn();
    FuncThread* _mpiThread;

    bool _pause;
    bool _isPaused;

    int64_t _bytesSent;
    int64_t _bytesRecv;
    double _timeWasted;

    NVMatrix _gpuTmp;
public:
    void sendAndRecv(int64_t id, NVMatrix& delta, NVMatrix& weights);
    int64_t newId();

    static NetworkManager* get();

    // Start the weight management threads.  Must be run from the GPU thread.
    static void initialize();

    static void pauseMPI();
    static void resumeMPI();
};

class Weights {
private:
    Matrix* _hWeights, *_hWeightsInc;
    NVMatrix* _weights, *_weightsInc, *_weightsGrad;

    float _epsW, _wc, _mom;
    bool _onGPU;
    int _numUpdates;
    static bool _autoCopyToGPU;
    int64_t _weightId;

    // Non-NULL if these weights are really shared from some other layer
    Weights* _srcWeights;

    NetworkManager *_netMgr;

public:
    NVMatrix& operator*() {
        return getW();
    }

    Weights(Weights& srcWeights, float epsW) : _srcWeights(&srcWeights), _epsW(epsW), _wc(0), _onGPU(false), _numUpdates(0),
                                               _weights(NULL), _weightsInc(NULL), _weightsGrad(NULL){
        _hWeights = &srcWeights.getCPUW();
        _hWeightsInc = &srcWeights.getCPUWInc();
        _mom = srcWeights.getMom();
        _netMgr = NetworkManager::get();
        _weightId = _netMgr->newId();

        if (_autoCopyToGPU) {
            copyToGPU();
        }
    }

    Weights(Matrix& hWeights, Matrix& hWeightsInc, float epsW, float wc, float mom)
        : _srcWeights(NULL), _hWeights(&hWeights), _hWeightsInc(&hWeightsInc), _numUpdates(0),
          _epsW(epsW), _wc(wc), _mom(mom), _onGPU(false), _weights(NULL),
          _weightsInc(NULL), _weightsGrad(NULL) {

        _netMgr = NetworkManager::get();
        _weightId = _netMgr->newId();

        if (_autoCopyToGPU) {
            copyToGPU();
        }
    }

    ~Weights() {
        delete _hWeights;
        delete _hWeightsInc;
        if (_srcWeights == NULL) {
            delete _weights;
            delete _weightsInc;
            delete _weightsGrad;
        }
    }

    static void setAutoCopyToGPU(bool autoCopyToGPU) {
        _autoCopyToGPU = autoCopyToGPU;
    }

    NVMatrix& getW() {
        assert(_onGPU);
        return *_weights;
    }

    NVMatrix& getGrad() {
        assert(_onGPU);
        return *_weightsGrad;
    }

    Matrix& getCPUW() {
        return *_hWeights;
    }

    Matrix& getCPUWInc() {
        return *_hWeightsInc;
    }

    int getNumRows() const {
        return _hWeights->getNumRows();
    }

    int getNumCols() const {
        return _hWeights->getNumCols();
    }

    void copyToCPU() {
        if (_srcWeights == NULL) {
            assert(_onGPU);
            _weights->copyToHost(*_hWeights);
            _weightsInc->copyToHost(*_hWeightsInc);
        }
    }

    // This function is assumed to be called in the order in which the layers
    // were defined
    void copyToGPU();

    void update(int numCases) {
        // Only true owner of weights updates
        if (_srcWeights == NULL && _epsW > 0) {
            assert(_onGPU);

            _weightsGrad->scale(_epsW / numCases);
            _weightsInc->add(*_weightsGrad, _mom, 1);
            if (_wc > 0) {
                _weightsInc->add(*_weights, -_wc * _epsW);
            }

            _netMgr->sendAndRecv(_weightId, *_weightsInc, *_weights);
            _numUpdates = 0;
        }
    }

    int incNumUpdates() {
        if (_srcWeights != NULL) {
            return _srcWeights->incNumUpdates();
        }
        return _numUpdates++;
    }

    // Returns the number of times a gradient has been computed for this
    // weight matrix during the current pass (interval between two calls of update())
    // through the net. This number will only be greater than 1 if this weight matrix
    // is *shared* by multiple layers in the net.
    int getNumUpdates() const {
        if (_srcWeights != NULL) {
            return _srcWeights->getNumUpdates();
        }
        return _numUpdates;
    }

    float getEps() const {
        return _epsW;
    }

    float getMom() const {
        return _mom;
    }

    float getWC() const {
        return _wc;
    }
};

class WeightList {
private:
    std::vector<Weights*> _weightList;

public:
    Weights& operator[](const int idx) const {
        return *_weightList[idx];
    }

    ~WeightList() {
        for (int i = 0; i < _weightList.size(); i++) {
            delete _weightList[i];
        }
    }

    WeightList() {
    }

    void addWeights(Weights& w) {
        _weightList.push_back(&w);
    }

    void update(int numCases) {
        for (int i = 0; i < getSize(); i++) {
            _weightList[i]->update(numCases);
        }
    }

    void copyToCPU() {
        for (int i = 0; i < getSize(); i++) {
            _weightList[i]->copyToCPU();
        }
    }

    void copyToGPU() {
        for (int i = 0; i < getSize(); i++) {
            _weightList[i]->copyToGPU();
        }
    }

    int getSize() {
        return _weightList.size();
    }
};

#endif	/* WEIGHTS_CUH */
