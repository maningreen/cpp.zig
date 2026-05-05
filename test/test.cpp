#include "test.hpp"

#include <iostream>

using namespace Foo;

template <typename T>
void Test<T>::testingFunction(double delta) {
    std::cout << delta << ' ' << testingChar << '\n';
}

template <typename T>
Test<T>::Test() {}

template <typename T>
Test<T>::Test(int i) {
    std::cout << "SDLF:KSF:L\n";
    std::cout << "test alt\n" << i << '\n';
}

template <typename T>
Test<T>::~Test() {}

void Test2::testingFunction(double delta) {
    std::cout << delta << '\n';
}

Test2::Test2() {
    testingChar = 0;
    testingItem = 0;
    testingptr = (int*)0;
    std::cout << "Wooo\n";
}
Test2::~Test2() {
    std::cout << "Test2 Died!\n";
}

float Foo::sum(float a, float b) {
    return a + b;
}

float sum(float a, float b) {
    return a + b;
}

Test<int> t;
