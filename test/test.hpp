struct Bar {
    int _3;
};

namespace Foo {

class Test {
  public:
    virtual ~Test();
    virtual void testingFunction(double delta);
    virtual void testingFunction(float delta);

    int testingItem;
    int* testingptr;
    char testingChar;

    void test() const;

    Test();
    Test(int i);
};

class Test2 : public Test {
  public:
    void testingFunction(double delta) override;
    Test2();
    ~Test2();

    static const int bar;
};


};  // namespace Foo
