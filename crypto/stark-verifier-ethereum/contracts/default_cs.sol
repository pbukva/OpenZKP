pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import './interfaces/ConstraintInterface.sol';
import './primefield.sol';
import './iterator.sol';
import './utils.sol';
import './trace.sol';
import './proof_types.sol';

abstract contract DefaultConstraintSystem is ConstraintSystem, Trace  {
    using Iterators for Iterators.IteratorUint;
    using PrimeField for uint256;
    using PrimeField for PrimeField.EvalX;
    using Utils for *;

    uint8 immutable CONSTRAINT_DEGREE;
    uint8 immutable NUM_OFFSETS;
    uint8 immutable NUM_COLUMNS;
    uint8 immutable BLOWUP;

    constructor(uint8 constraint_degree, uint8 num_offests, uint8 num_col, uint8 blowup) public {
        CONSTRAINT_DEGREE = constraint_degree;
        NUM_OFFSETS = num_offests;
        NUM_COLUMNS = num_col;
        BLOWUP = blowup;
    }

    // This function calcluates the adjustments to each query point which are implied
    // by the offsets and degree of the constraint system
    // It returns the low degree polynomial points at the query indcies
    function get_polynomial_points(
        ProofTypes.OodsEvaluationData memory data,
        PrimeField.EvalX memory eval,
        uint256[] memory oods_coeffiecients,
        uint256[] memory queries,
        uint256 oods_point
    ) internal returns (uint256[] memory) {
        trace('oods_prepare_inverses', true);
        uint256[] memory inverses = oods_prepare_inverses(
            queries,
            eval,
            oods_point,
            data.log_trace_length + 4,
            data.log_trace_length
        );
        trace('oods_prepare_inverses', false);
        uint256[] memory results = new uint256[](queries.length);

        // Init an iterator over the oods coeffiecients
        Iterators.IteratorUint memory coeffiecients = Iterators.init_iterator(oods_coeffiecients);
        uint256[] memory layout = layout_col_major();
        for (uint256 i = 0; i < queries.length; i++) {
            uint256 result = 0;
            {
            trace('get_polynomial_points_loop_1', true);
            // These held pointers help soldity make the stack work
            uint256[] memory trace_oods_value = data.trace_oods_values;
            uint256[] memory trace_values = data.trace_values;
            for (uint256 j = 0; j < trace_oods_value.length; ) {
                uint256 loaded_trace_data = trace_oods_value[j];
                // J*2 is the col index when the layout is in coloum major form
                // NUM_COLUMNS*i idenifes the start of this querry's row values
                uint256 calced_index = NUM_COLUMNS*i + layout[j*2];
                uint256 numberator = addmod(trace_values[calced_index], (PrimeField.MODULUS - loaded_trace_data), PrimeField.MODULUS);

                // Our trace layout is: (Col, Row Inverse Index),
                // So the following will tell us where to look in the inverses
                uint256 row = layout[j*2+1];
                calced_index = (NUM_OFFSETS+1)*i + row;
                uint256 denominator_inv = inverses[calced_index];

                uint256 element = mulmod(numberator, denominator_inv, PrimeField.MODULUS);
                uint256 coef = coeffiecients.next();
                uint256 next_term = mulmod(mulmod(element, coef, PrimeField.MODULUS), PrimeField.MONTGOMERY_R_INV, PrimeField.MODULUS);
                result = addmod(result, next_term, PrimeField.MODULUS);

                assembly {
                    j := add(j, 1)
                }
            }
            trace('get_polynomial_points_loop_1', false);

            }

            trace('get_polynomial_points_loop_2', true);
            uint256 denominator_inv = inverses[i * (NUM_OFFSETS+1) + NUM_OFFSETS];
            uint256 len = CONSTRAINT_DEGREE;
            uint256[] memory constraint_values = data.constraint_values;
            uint256[] memory constraint_oods_values = data.constraint_oods_values;
            for (uint256 j = 0; j < len; ) {
                uint256 loaded_constraint_value = constraint_values[i * len + j];
                uint256 loaded_oods_value = constraint_oods_values[j];
                uint256 numberator = addmod(loaded_constraint_value, PrimeField.MODULUS - loaded_oods_value, PrimeField.MODULUS);
                uint256 element = mulmod(numberator, denominator_inv, PrimeField.MODULUS);
                uint256 coef = coeffiecients.next();
                uint256 next_term = mulmod(mulmod(element, coef, PrimeField.MODULUS), PrimeField.MONTGOMERY_R_INV, PrimeField.MODULUS);
                result = addmod(result, next_term, PrimeField.MODULUS);

                assembly {
                    j := add(j, 1)
                }
            }
            trace('get_polynomial_points_loop_2', false);

            results[i] = result;
            // This resets the iterator to start from the begining again
            coeffiecients.index = 0;
        }

        return results;
    }

    // TODO - Make batch invert a function
    // TODO - Attempt to make batch invert work in place
    // Note - This function should be auto generated along
    function oods_prepare_inverses(
        uint256[] memory queries,
        PrimeField.EvalX memory eval,
        uint256 oods_point,
        uint8 log_eval_domain_size,
        uint8 log_trace_len
    ) internal returns(uint256[] memory) {
        // The layout rows function gives us a listing of all of the row offset which
        // will be accessed for this calculation
        uint256[] memory trace_rows = layout_rows();
        oods_point = oods_point.from_montgomery();
        uint256 trace_generator = eval.eval_domain_generator.fpow(BLOWUP);
        uint256[] memory batch_in = new uint256[]((NUM_OFFSETS+1) * queries.length);
        // For each query we we invert several points used in the calculation of
        // the commited polynomial.
        {
        uint256 oods_constraint_power = oods_point.fpow(uint256(CONSTRAINT_DEGREE));
        uint256[] memory generator_powers = new uint256[](trace_rows.length);

        for (uint i = 0; i < trace_rows.length; i++) {
            generator_powers[i] = trace_generator.fpow(trace_rows[i]);
        }

        for (uint256 i = 0; i < queries.length; i++) {
            // Get the shifted eval point
            uint256 x;
            {
                uint256 query = queries[i];
                uint256 bit_reversed_query = query.bit_reverse(log_eval_domain_size);
                x = eval.lookup(bit_reversed_query);
                x = x.fmul(PrimeField.GENERATOR);
            }

            for (uint j = 0; j < trace_rows.length; j ++) {
                uint256 loaded_gen_power = generator_powers[j];
                uint256 shifted_oods = oods_point.fmul(loaded_gen_power);
                batch_in[i*(NUM_OFFSETS+1) + j] = x.fsub(shifted_oods);
            }
            // This is the shifted x - oods_point^(degree)
            batch_in[i*(NUM_OFFSETS+1) + NUM_OFFSETS] = x.fsub(oods_constraint_power);
        }
        }

        trace('oods_batch_invert', true);
        uint256[] memory batch_out = new uint256[](batch_in.length);
        uint256 carried = 1;
        uint256 pre_stored_len = batch_in.length;
        for (uint256 i = 0; i < pre_stored_len; ) {
            carried = mulmod(carried, batch_in[i], PrimeField.MODULUS);
            batch_out[i] = carried;
            assembly {
                i := add(i, 1)
            }
        }

        uint256 inv_prod = carried.inverse();

        for (uint256 i = batch_out.length - 1; i > 0; ) {
            batch_out[i] = mulmod(inv_prod, batch_out[i - 1], PrimeField.MODULUS);
            inv_prod = inv_prod.fmul(batch_in[i]);
            assembly {
                i := sub(i, 1)
            }
        }
        batch_out[0] = inv_prod;
        trace('oods_batch_invert', false);
        return batch_out;
    }

    // TODO - Move this to a util file or default implementation
    uint8 constant LOG2_TARGET = 8;
    // This function produces the default fri layout from the trace length
    function default_fri_layout(uint8 log_trace_len) internal view returns (uint8[] memory) {
        uint256 num_reductions;
        if (log_trace_len > LOG2_TARGET) {
            num_reductions = log_trace_len - LOG2_TARGET;
        } else {
            num_reductions = log_trace_len;
        }

        uint8[] memory result;
        if (num_reductions % 3 != 0) {
            result = new uint8[](1 + (num_reductions / 3));
            result[result.length - 1] = uint8(num_reductions % 3);
        } else {
            result = new uint8[](num_reductions / 3);
        }
        for (uint256 i = 0; i < (num_reductions / 3); i++) {
            result[i] = 3;
        }
        return result;
    }

    // Returns an array of all of the row offsets which are used
    function layout_rows() internal pure virtual returns(uint256[] memory);
    // Returns a set of pairs (col, offset) for each element in the trace layout
    // Where the col is what collum the trace element is and the offest is
    // where in the inverse memory layout the offest is.
    function layout_col_major() internal pure virtual returns(uint256[] memory);
}
