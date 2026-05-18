#include "test.hpp"

#include <iostream>

using namespace Foo;

void Test::testingFunction(double delta) {
  std::cout << delta << ' ' << testingChar << '\n';
}

void Test::testingFunction(float delta) {
  std::cout << delta << ' ' << testingChar << '\n';
}

Test::Test() {}

Test::Test(int i) {
  std::cout << "SDLF:KSF:L\n";
  std::cout << "test alt\n" << i << '\n';
}

void Foo::Test::test() const {
    std::cout << "TEST CALLED";
}

Test::~Test() {}

void Test2::testingFunction(double delta) { std::cout << delta << '\n'; }

Test2::Test2() {
  testingChar = 0;
  testingItem = 0;
  testingptr = (int *)0;
  std::cout << "Wooo\n";
}
Test2::~Test2() { std::cout << "Test2 Died!\n"; }

float sum(float a, float b) { return a + b; }

double sum(double a, double b) { return a + b; }
