struct Bar {
    int _3;
};

namespace Foo {

template <typename T>
class Test {
  public:
    virtual ~Test();
    virtual void testingFunction(double delta);

    int testingItem;
    int* testingptr;
    char testingChar;

    void test() const;

    Test();
    Test(int i);
};

class Test2 : public Test<Bar> {
  public:
    void testingFunction(double delta) override;
    Test2();
    ~Test2();

    static const int bar;
};

float sum(float a, float b);

};  // namespace Foo

float sum(float a, float b);

float bum();
