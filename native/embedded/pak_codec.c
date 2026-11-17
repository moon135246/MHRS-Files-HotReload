#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <zstd.h>
#if ZSTD_VERSION_NUMBER != 10507
#error "The Rise player build requires Zstandard 1.5.7"
#endif

static PyObject *decompress(PyObject *self, PyObject *args) {
    const char *src;
    Py_ssize_t stored, size;
    if (!PyArg_ParseTuple(args, "y#n", &src, &stored, &size))
        return NULL;
    if (size < 0 || ZSTD_findFrameCompressedSize(src, stored) != (size_t)stored) {
        PyErr_SetString(PyExc_ValueError, "Invalid Zstd frame in Rise PAK");
        return NULL;
    }
    PyObject *output = PyBytes_FromStringAndSize(NULL, size);
    if (!output)
        return NULL;
    size_t actual = ZSTD_decompress(PyBytes_AS_STRING(output), size, src, stored);
    if (ZSTD_isError(actual) || actual != (size_t)size) {
        Py_DECREF(output);
        PyErr_SetString(PyExc_ValueError, "Invalid Zstd payload in Rise PAK");
        return NULL;
    }
    return output;
}

static PyMethodDef functions[] = {{"decompress", decompress, METH_VARARGS, NULL}, {NULL, NULL, 0, NULL}};
static PyModuleDef module = {PyModuleDef_HEAD_INIT, "_mhrs_pak", NULL, -1, functions};
PyMODINIT_FUNC PyInit__mhrs_pak(void) { return PyModule_Create(&module); }
